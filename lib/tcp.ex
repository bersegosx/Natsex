defmodule Natsex.TCPConnector do
  @moduledoc """
  Heart of Natsex
  """

  use Connection
  require Logger

  alias Natsex.Parser
  alias Natsex.CommandEater

  @initial_state %{
    connection: :disconnected,

    socket: nil,
    server_info: nil,
    buffer: "",
    subscribers: %{},
    subscribers_monitor: %{},
    pong_waiter: nil,
    ping_timer_ref: nil,

    config: %{
      host: "localhost",
      port: 4222,
      verbose: true,
      tls_required: false,
      pedantic: true,
      user: nil,
      pass: nil,
      auth_token: nil
    },

    opts: %{
      connect_timeout: 200,
      ping_interval: 60_000,
      allow_reconnect: true,
      reconnect_time_wait: 1_000
    }
  }

  @pong_receive_timeout Application.get_env(:natsex, :pong_receive_timeout)

  @doc false
  def subscribe(pid, subject, who, sid \\ nil, queue_group \\ nil) do
    Connection.call(pid, {:subscribe, who, subject, sid, queue_group})
  end

  @doc false
  def unsubscribe(pid, sid, max_messages \\ nil) do
    Connection.cast(pid, {:unsubscribe, sid, max_messages})
  end

  @doc false
  def publish(pid, subject, payload \\ "", reply \\ nil, timeout \\ 5_000) do
    Connection.call(pid, {:publish, subject, reply, payload}, timeout)
  end

  @doc false
  def request(pid, subject, payload, timeout \\ 1000) do
    reply_inbox = "inbox." <> UUID.uuid4()

    waiter_task = Task.async(fn ->
      receive do
        {:natsex_message, {^reply_inbox, _sid, _}, message_body} ->
          message_body
      end
    end)

    reply_sid = subscribe(pid, reply_inbox, waiter_task.pid)
    :ok = publish(pid, subject, payload, reply_inbox)

    case Task.yield(waiter_task, timeout) || Task.shutdown(waiter_task) do
      nil ->
        unsubscribe(pid, reply_sid)
        :timeout

      {:ok, _} = resp ->
        resp
    end
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  def start_link(opts) do
    Connection.start_link(__MODULE__, opts)
  end

  def init(opts) do
    opts = Map.merge(@initial_state.opts, Enum.into(opts, %{}))
    {opts_config, opts} = Map.pop(opts, :config, %{})
    config = Map.merge(@initial_state.config, opts_config)

    {:connect, :init, %{@initial_state| config: config, opts: opts}}
  end

  def connect(info, %{config: config} = state) do
    Logger.debug("Connecting to server, config: #{inspect config}, info: #{inspect info}")
    state = %{state| connection: :disconnected}

    with {:ok, socket} <- :gen_tcp.connect(to_charlist(config.host), config.port,
                            [:binary, active: false],
                            state.opts.connect_timeout),
         {:ok, info_msg} <- :gen_tcp.recv(socket, 0) do

      Logger.debug("<- #{inspect info_msg}")

      state = %{state| socket: socket}
      {server_info, ping_ref} = process_info_message(info_msg, state)
      :inet.setopts(socket, active: :once)

      {:ok, %{state|
              connection: :connected,
              server_info: server_info,
              ping_timer_ref: ping_ref}}
    else
      {:error, _reason} ->
        if state.opts.allow_reconnect do
          {:backoff, state.opts.reconnect_time_wait, state}
        else
          {:stop, :normal, state}
        end
    end
  end

  def handle_call(_, _, %{connection: :disconnected} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  def handle_call(
    {:subscribe, who, subject, sid, queue_group},
    _from,
    %{subscribers: subscribers, subscribers_monitor: monitors} = state) do

    sid = if sid, do: sid, else: UUID.uuid4()
    msg = Parser.create_message("SUB", [subject, queue_group, sid])
    monitor_ref = Process.monitor(who)

    send_to_server(state.socket, msg)

    {:reply, sid, %{state|
                    subscribers: Map.put(subscribers, sid, who),
                    subscribers_monitor: Map.put(monitors, monitor_ref, sid)}}
  end

  def handle_call({:publish, subject, reply_to, payload}, _from, state) do
    if byte_size(payload) > state.server_info.max_payload do
      {:reply,
        {:error,
         "Message is too big (limit: #{state.server_info.max_payload}, " <>
         "current: #{byte_size(payload)})"
        },
      state}
    else
      msg = Parser.command_publish(subject, reply_to, payload)
      send_to_server(state.socket, msg)

      {:reply, :ok, state}
    end
  end

  def handle_cast({:unsubscribe, sid, max_messages}, state) do
    msg = Parser.create_message("UNSUB", [sid, max_messages])
    send_to_server(state.socket, msg)

    {:noreply, state}
  end

  def handle_info({:tcp, socket, msg}, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)

    Logger.debug "<- #{inspect msg}"

    {rest_buffer, commands} = CommandEater.feed(state.buffer <> msg)
    for command <- commands do
      case command do
        "PING" ->
          send_to_server(state.socket, Parser.create_message("PONG"))

        "+OK" ->
          :ok

        "PONG" ->
          send(state.pong_waiter, :pong)
          :pong

        "INFO " <> _ ->
          send(self(), {:server_info, command})

        "-ERR " <> error_msg ->
          error_msg = String.slice(error_msg, 1..-2)
          Logger.error "received -ERR: #{error_msg}"

        {"MSG " <> _ = message_header, message_body} ->
          send(self(), {:server_msg, message_header, message_body})
      end
    end

    {:noreply, %{state| buffer: rest_buffer}}
  end

  def handle_info({:server_info, info_msg}, state) do
    {server_info, ping_ref} = process_info_message(info_msg, state)
    {:noreply, %{state| server_info: server_info, ping_timer_ref: ping_ref}}
  end

  def handle_info(
    {:server_msg, message_header, message_body},
    %{subscribers: subscribers} = state) do

    Logger.debug "New message: #{message_header}, body: #{inspect message_body}"

    {"MSG", [subject | [sid|params] ]} = Parser.parse(message_header)
    {reply_to, message_body_length} =
      case params do
        [size] -> {nil, size}
        [reply_to, size] -> {reply_to, size}
      end
    Logger.debug "Reply: #{reply_to}, size: #{message_body_length}"

    {message_body_length, _} = Integer.parse(message_body_length, 10)
    if byte_size(message_body) != message_body_length do
      Logger.error ":message_body_length_mismatch, #{message_body_length}, #{byte_size(message_body)}"
      Process.exit(self(), :message_body_length_mismatch)
    end

    send(subscribers[sid], {:natsex_message, {subject, sid, reply_to}, message_body})

    {:noreply, state}
  end

  def handle_info(:keep_alive, state) do
    natsex_pid = self()

    {:ok, pong_waiter} = Task.start_link(fn ->
      receive do
        :pong -> Logger.debug("Server PONG was received")
      after
        @pong_receive_timeout -> send(natsex_pid, :keep_alive_timeout)
      end

      Process.send_after(natsex_pid, :keep_alive, state.opts.ping_interval)
    end)

    send_to_server(state.socket, Parser.create_message("PING"))

    {:noreply, %{state| pong_waiter: pong_waiter}}
  end

  def handle_info(:keep_alive_timeout, state) do
    Logger.error("Server didn't respond on PING command")
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _sock}, state) do
    Process.cancel_timer(state.ping_timer_ref)
    {:connect, :tcp_closed, %{state| ping_timer_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _object, _reason}, state) do
    Logger.debug(":DOWN")

    {sid, monitors} = Map.pop(state.subscribers_monitor, ref)
    {_, subscribers} = Map.pop(state.subscribers, sid)

    if sid do
      send_to_server(state.socket, Parser.create_message("UNSUB", [sid]))
    end

    {:noreply, %{state| subscribers_monitor: monitors,
                        subscribers: subscribers}}
  end

  def terminate(_reason, %{connection: :connected, subscribers: subscribers} = state) do
    Enum.map(subscribers, fn ({sid, _who}) ->
      send_to_server(state.socket, Parser.create_message("UNSUB", [sid]))
    end)
  end
  def terminate(_, _) do end

  defp send_to_server(sock, msg) do
    :gen_tcp.send(sock, msg)
    Logger.debug("-> #{inspect msg}")
  end

  defp process_info_message(data_str, %{config: config} = state) do
    {"INFO", server_info} = Parser.parse_json_response(data_str)

    connect_data = %{
      verbose: config.verbose, lang: "elixir", name: "natsex",
      version: Natsex.MixProject.project()[:version],
      pedantic: config.pedantic, tls_required: config.tls_required,
      protocol: 0
    }

    connect_data =
      if server_info.auth_required do
        Map.merge(connect_data, %{
          user: config.user, pass: config.pass, auth_token: config.auth_token
        })
      else
        connect_data
      end

    msg = Parser.create_json_command("CONNECT", connect_data)
    send_to_server(state.socket, msg)
    Logger.debug("Connected")

    ping_ref = Process.send_after(self(), :keep_alive, state.opts.ping_interval)

    {server_info, ping_ref}
  end
end
