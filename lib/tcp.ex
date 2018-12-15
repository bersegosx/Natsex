defmodule Natsex.TCPConnector do
  @moduledoc """
  Heart of Natsex
  """

  use Connection
  require Logger

  alias Natsex.{Parser, CommandEater, Validator, Transport}

  @initial_state %{
    connection: :disconnected,

    socket: nil,
    server_info: nil,
    buffer: "",
    subscribers: %{},
    subscribers_monitor: %{},
    pong_waiter: nil,
    ping_timer_ref: nil,

    request_waiters: %{},
    reply_inbox: nil,

    config: %{
      host: "localhost",
      port: 4222,

      tls_required: false,
      cert_path: nil,
      cert_key_path: nil,

      verbose: false,
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

  @pong_receive_timeout Application.get_env(:natsex, :pong_receive_timeout, 5_000)
  @reply_subject_prefix "_INBOX.REPLY."

  @doc false
  def subscribe(pid, subject, who, sid \\ nil, queue_group \\ nil) do
    case Validator.is_valid(subject) do
      :ok ->
        Connection.call(pid, {:subscribe, who, subject, sid, queue_group})

      error ->
        {:error, error}
    end
  end

  @doc false
  def unsubscribe(pid, sid, max_messages \\ nil) do
    Connection.cast(pid, {:unsubscribe, sid, max_messages})
  end

  @doc false
  def publish(pid, subject, payload \\ "", reply \\ nil, timeout \\ 5_000) do
    with :ok <- Validator.is_valid(subject),
         :ok <- Validator.is_valid(reply, true)
    do
      Connection.call(pid, {:publish, subject, reply, payload}, timeout)
    else
      error ->
        {:error, error}
    end
  end

  @doc false
  def request(pid, subject, payload, timeout \\ 1000) do
    reply_inbox = @reply_subject_prefix <> UUID.uuid4()
    :ok = publish(pid, subject, payload, reply_inbox)

    Connection.call(pid, {:request, reply_inbox}, timeout)
  end

  def get_socket(pid) do
    GenServer.call(pid, :get_socket)
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

    # remove old ping timer
    if state.ping_timer_ref do
      Process.cancel_timer(state.ping_timer_ref)
    end
    state = %{state| connection: :disconnected, ping_timer_ref: nil}

    case Transport.connect(state, config) do
      {:ok, _} = result ->
        result

      {:error, reason} ->
        Logger.debug("Can't connect, reason: #{inspect reason}")

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

  def handle_call({:request, inbox_uuid}, from, %{reply_inbox: nil} = state) do
    {:reply, sid, state} = handle_call(
      {:subscribe, self(), @reply_subject_prefix <> ">", nil, nil},
      from,
      state
    )
    handle_call({:request, inbox_uuid}, from, %{state| reply_inbox: sid})
  end

  def handle_call({:request, inbox_uuid}, from, state) do
    {:noreply, %{state|
      request_waiters: Map.put(state.request_waiters, inbox_uuid, from)}}
  end

  def handle_call(:get_socket, _from, state) do
    {:reply, state, state}
  end

  def handle_call(
    {:subscribe, who, subject, sid, queue_group},
    _from,
    %{subscribers: subscribers, subscribers_monitor: monitors} = state) do

    sid = if sid, do: sid, else: UUID.uuid4()
    msg = Parser.create_message("SUB", [subject, queue_group, sid])
    monitor_ref = Process.monitor(who)

    send_to_server(state, msg)

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
      send_to_server(state, msg)

      {:reply, :ok, state}
    end
  end

  def handle_cast({:unsubscribe, sid, max_messages}, state) do
    msg = Parser.create_message("UNSUB", [sid, max_messages])
    send_to_server(state, msg)

    {:noreply, state}
  end

  def handle_info({:tcp, socket, msg}, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
    handle_info({:new_transport_data, socket, msg}, state)
  end

  def handle_info({:ssl, socket, msg}, %{socket: socket} = state) do
    :ssl.setopts(socket, active: :once)
    handle_info({:new_transport_data, socket, msg}, state)
  end

  def handle_info({:new_transport_data, socket, msg}, %{socket: socket} = state) do
    Logger.debug "<- #{inspect msg}"

    {rest_buffer, commands} = CommandEater.feed(state.buffer <> msg)
    for command <- commands do
      case command do
        "PING" ->
          send_to_server(state, Parser.create_message("PONG"))

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
    %{subscribers: subscribers, request_waiters: request_waiters} = state) do

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

    state =
      if String.starts_with?(subject, @reply_subject_prefix) do
        {client, request_waiters} = Map.pop(request_waiters, subject)
        GenServer.reply(client, {:ok, message_body})
        %{state| request_waiters: request_waiters}
      else
        send(subscribers[sid], {:natsex_message, {subject, sid, reply_to}, message_body})
        state
      end

    {:noreply, state}
  end

  def handle_info(:keep_alive, state) do
    natsex_pid = self()

    pong_waiter = spawn_link(fn ->
      receive do
        :pong -> Logger.debug("Server PONG was received")
      after
        @pong_receive_timeout -> send(natsex_pid, :keep_alive_timeout)
      end

      Process.send_after(natsex_pid, :keep_alive, state.opts.ping_interval)
    end)

    send_to_server(state, Parser.create_message("PING"))

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

  def handle_info({:ssl_closed, sock}, state) do
    handle_info({:tcp_closed, sock}, state)
  end

  def handle_info({:DOWN, ref, :process, _object, reason}, state) do
    Logger.debug(reason, label: ":DOWN")

    {sid, monitors} = Map.pop(state.subscribers_monitor, ref)
    {_, subscribers} = Map.pop(state.subscribers, sid)

    if sid do
      send_to_server(state, Parser.create_message("UNSUB", [sid]))
    end

    {:noreply, %{state| subscribers_monitor: monitors,
                        subscribers: subscribers}}
  end

  def terminate(_reason, %{connection: :connected, subscribers: subscribers} = state) do
    Enum.map(subscribers, fn ({sid, _who}) ->
      send_to_server(state, Parser.create_message("UNSUB", [sid]))
    end)
  end
  def terminate(_, _) do end

  defp send_to_server(state, msg) do
    Transport.send_to_server(state, msg)
  end

  def process_info_message(data_str, %{config: config} = state) do
    {"INFO", server_info} = Parser.parse_json_response(data_str)

    connect_data = %{
      verbose: config.verbose, lang: "elixir", name: "natsex",
      version: Natsex.MixProject.project()[:version],
      pedantic: config.pedantic, tls_required: config.tls_required,
      protocol: 0
    }

    connect_data =
      if Map.get(server_info, :auth_required, false) do
        Map.merge(connect_data, %{
          user: config.user, pass: config.pass, auth_token: config.auth_token
        })
      else
        connect_data
      end

    msg = Parser.create_json_command("CONNECT", connect_data)
    send_to_server(state, msg)
    Logger.debug("Connected")

    ping_ref = Process.send_after(self(), :keep_alive, state.opts.ping_interval)

    {server_info, ping_ref}
  end
end
