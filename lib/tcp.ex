defmodule Natsex.TCPConnector do
  @moduledoc """
  Heart of Natsex
  """

  use GenServer
  require Logger

  alias Natsex.Parser
  alias Natsex.CommandEater

  @default_options config: %{},
                   connect_timeout: 200,
                   ping_interval: 60_000

  @default_config %{
    host: "localhost",
    port: 4222,
    verbose: true,
    tls_required: false,
    pedantic: true,
    user: nil,
    pass: nil,
    auth_token: nil
  }

  @initial_state %{
    socket: nil,
    server_info: nil,
    buffer: "",
    subscibers: %{},

    config: nil,
    ping_interval: nil,
    pong_waiter: nil,
  }

  @pong_receive_timeout Application.get_env(:natsex, :pong_receive_timeout)

  @doc false
  def subscribe(pid, subject, who, sid \\ nil, queue_group \\ nil) do
    GenServer.call(pid, {:subscribe, who, subject, sid, queue_group})
  end

  @doc false
  def unsubscribe(pid, sid, max_messages \\ nil) do
    GenServer.cast(pid, {:unsubscribe, sid, max_messages})
  end

  @doc false
  def publish(pid, subject, payload \\ "", reply \\ nil, timeout \\ 5_000) do
    GenServer.call(pid, {:publish, subject, reply, payload}, timeout)
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
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    opts = Keyword.merge(@default_options, opts)
    config = Map.merge(@default_config, opts[:config])

    Logger.debug("Connecting to server, config: #{inspect config}")

    case :gen_tcp.connect(to_charlist(config.host), config.port,
                          [:binary, active: false],
                          opts[:connect_timeout]) do
      {:ok, socket} ->
        {:ok, %{@initial_state |
                socket: socket,
                config: config,
                ping_interval: opts[:ping_interval]}, 0}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(
    {:subscribe, who, subject, sid, queue_group},
    _from,
    %{subscibers: subscibers} = state) do

    sid = if sid, do: sid, else: UUID.uuid4()
    msg = Parser.create_message("SUB", [subject, queue_group, sid])
    send_to_server(state.socket, msg)

    {:reply, sid, %{state| subscibers: Map.put(subscibers, sid, who)}}
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

  @doc """
  Post init func
  """
  def handle_info(:timeout, %{socket: socket} = state) do
    {:ok, info_msg} = :gen_tcp.recv(socket, 0)
    Logger.debug("<- #{inspect info_msg}")
    server_info = process_info_message(info_msg, state)
    :inet.setopts(socket, active: :once)

    {:noreply, %{state| server_info: server_info}}
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
    server_info = process_info_message(info_msg, state)
    {:noreply, %{state| server_info: server_info}}
  end

  def handle_info(
    {:server_msg, message_header, message_body},
    %{subscibers: subscibers} = state) do

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

    send(subscibers[sid], {:natsex_message, {subject, sid, reply_to}, message_body})

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

      Process.send_after(natsex_pid, :keep_alive, state.ping_interval)
    end)

    send_to_server(state.socket, Parser.create_message("PING"))

    {:noreply, %{state| pong_waiter: pong_waiter}}
  end

  def handle_info(:keep_alive_timeout, state) do
    Logger.error("Server didn't respond on PING command")
    {:noreply, state}
  end

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

    Process.send_after(self(), :keep_alive, state.ping_interval)

    server_info
  end
end
