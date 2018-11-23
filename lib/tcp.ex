defmodule Natsex.TCPConnector do
  @moduledoc """
  Heart of Natsex
  """

  use GenServer
  require Logger

  alias Natsex.Parser
  alias Natsex.CommandEater

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

  @doc false
  def get_state do
    # used only for tests
    GenServer.call(:natsex_connector, :state)
  end

  @doc false
  def subscribe(subject, who, sid \\ nil, queue_group \\ nil) do
    GenServer.call(:natsex_connector, {:subscribe, who, subject, sid, queue_group})
  end

  @doc false
  def unsubscribe(sid, max_messages \\ nil) do
    GenServer.cast(:natsex_connector, {:unsubscribe, sid, max_messages})
  end

  @doc false
  def publish(subject, payload \\ "", reply \\ nil) do
    GenServer.call(:natsex_connector, {:publish, subject, reply, payload})
  end

  def start_link(config, connect_timeout) do
    GenServer.start_link(__MODULE__, [config, connect_timeout], name: :natsex_connector)
  end

  def init([config, connect_timeout]) do
    config =
      if is_map(config) do
        Map.merge(@default_config, config)
      else
        @default_config
      end

    Logger.debug("Connecting to server ..., config: #{inspect config}")

    opts = [:binary, active: :once]
    case :gen_tcp.connect(to_charlist(config.host), config.port, opts,
                          connect_timeout) do
      {:ok, socket} ->
        {:ok, %{
          socket: socket,
          server_info: nil,
          reader: %{
            need_more: false,
            buffer: ""
          },
          subscibers: %{},
          config: config
        }}

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
    Logger.debug "Subscribe: #{inspect msg}"
    :gen_tcp.send(state.socket, msg)

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
      Logger.debug "Publish command: #{inspect msg}"
      :gen_tcp.send(state.socket, msg)

      {:reply, :ok, state}
    end
  end

  def handle_cast({:unsubscribe, sid, max_messages}, state) do
    msg = Parser.create_message("UNSUB", [sid, max_messages])
    Logger.debug "Unsubscibe command: #{inspect msg}"
    :gen_tcp.send(state.socket, msg)

    {:noreply, state}
  end

  def handle_info(
    {:tcp, socket, msg},
    %{socket: socket, reader: reader} = state) do

    :inet.setopts(socket, active: :once)

    Logger.debug "TCP -> #{inspect msg}"

    {rest_buffer, commands} = CommandEater.feed(reader.buffer <> msg)
    for command <- commands do
      case command do
        "PING" ->
          send(self(), :server_ping)

        "+OK" ->
          :ok

        "PONG" ->
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

    {:noreply, %{state| reader: %{buffer: rest_buffer}}}
  end

  def handle_info({:server_info, data_str}, state) do
    {"INFO", server_info} = Parser.parse_json_response(data_str)
    Logger.debug("Connected")

    send(self(), :connect)

    {:noreply, %{state| server_info: server_info}}
  end

  def handle_info(
    :connect,
    %{server_info: server_info, config: config} = state) do

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
    :gen_tcp.send(state.socket, msg)
    Logger.debug "<- #{inspect msg}"

    {:noreply, %{state| server_info: server_info}}
  end

  def handle_info(:server_ping, %{socket: socket} = state) do
    Logger.debug("server send PING")
    :gen_tcp.send(socket, Parser.create_message("PONG"))
    Logger.debug "sent PONG"

    {:noreply, state}
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
end
