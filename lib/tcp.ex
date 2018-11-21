defmodule Natsex.TCPConnector do
  use GenServer
  require Logger

  alias Natsex.Parser

  @default_config %{
    host: "localhost",
    port: 4222,
    verbose: true,
    tls_required: false,
    pedantic: true,
    user: nil,
    pass: nil
  }

  def subscribe(subject, who, sid \\ nil, queue_group \\ nil) do
    GenServer.call(:natsex_connector, {:subscribe, who, subject, sid, queue_group})
  end

  def unsubscribe(sid, max_messages \\ nil) do
    GenServer.cast(:natsex_connector, {:unsubscribe, sid, max_messages})
  end

  def publish(subject, payload \\ "", reply \\ nil) do
    GenServer.cast(:natsex_connector, {:publish, subject, reply, payload})
  end

  def start_link(config \\ nil) do
    GenServer.start_link(__MODULE__, config, name: :natsex_connector)
  end

  def init(config) do
    config = if is_map(config) do
      Map.merge(@default_config, config)
    else
      @default_config
    end

    Logger.debug("Connecting to server ..., config: #{inspect config}")

    opts = [:binary, active: :once]
    {:ok, socket} = :gen_tcp.connect(to_charlist(config.host), config.port, opts)
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

  def handle_cast({:unsubscribe, sid, max_messages}, state) do
    msg = Parser.create_message("UNSUB", [sid, max_messages])
    Logger.debug "Unsubscibe command: #{inspect msg}"
    :gen_tcp.send(state.socket, msg)

    {:noreply, state}
  end

  def handle_cast({:publish, subject, reply_to, payload}, state) do
    msg = Parser.command_publish(subject, reply_to, payload)
    Logger.debug "Publish command: #{inspect msg}"
    :gen_tcp.send(state.socket, msg)

    {:noreply, state}
  end

  def handle_info(
    {:tcp, socket, msg},
    %{socket: socket, reader: reader} = state) do

    :inet.setopts(socket, active: :once)

    Logger.debug "TCP -> #{inspect msg}"

    new_state =
      if String.ends_with?(msg, "\r\n") do
        commands = reader.buffer <> msg
        Logger.debug "Full buffer: #{inspect commands}"

        {has_msg_command, msg_command_buffer} = Enum.reduce(
          String.split(commands, "\r\n", trim: true),
          {false, ""},
          fn (command, {has_msg_command, msg_command_buffer}) ->

          Logger.debug "line: #{command}"
          Logger.debug("line debug: #{inspect has_msg_command}, #{inspect msg_command_buffer}")

          cond do
            String.starts_with?(command, "INFO ") ->
              send(self(), {:server_info, command})

            command == "PING" ->
              send(self(), {:server_ping, command})

            command == "+OK" ->
              :ok

            String.starts_with?(command, "-ERR ") ->
              "-ERR " <> error_msg = command
              error_msg = String.slice(error_msg, 1..-2)
              Logger.error "received -ERR: #{error_msg}"

            String.starts_with?(command, "MSG ") ->
              Logger.debug("Command MSG, debug: #{inspect command}")
              has_msg_command = true
              msg_command_buffer = command
              Logger.debug("Command MSG, has_msg_command #{inspect has_msg_command}, #{inspect msg_command_buffer}")

            true ->
              Logger.debug("default case, has_msg_command #{inspect has_msg_command}")
              if has_msg_command do
                data = command
                has_msg_command = false

                send(self(), {:server_msg, msg_command_buffer, data})

                msg_command_buffer = ""
              else
                Logger.debug "Unhandled command: #{inspect command}"
              end
            end

          {has_msg_command, msg_command_buffer}

          end
        )

        if has_msg_command do
          # msg body wasnt received
          %{state| reader: %{
            need_more: true, buffer: msg_command_buffer
          }}
        else
          state
        end

      else
        %{state| reader: %{need_more: true, buffer: state.buffer <> msg}}
      end

    {:noreply, new_state}
  end

  def handle_info(
    {:server_info, data_str},
    %{config: config, server_info: server_info} = state) do

    {"INFO", server_info} = Parser.parse_json_response(data_str)
    Logger.debug("Connected")

    connect_data = %{
      verbose: config.verbose, lang: "elixir", name: "natsex",
      version: Natsex.MixProject.project()[:version],
      pedantic: config.pedantic, tls_required: config.tls_required,
      protocol: 0
    }

    connect_data =
      if server_info.auth_required do
        Map.merge(connect_data, %{user: config.user, pass: config.pass})
      else
        connect_data
      end

    msg = Parser.create_json_command("CONNECT", connect_data)
    :gen_tcp.send(state.socket, msg)
    Logger.debug "<- #{inspect msg}"

    {:noreply, %{state| server_info: server_info}}
  end

  def handle_info({:server_ping, data_str}, %{socket: socket} = state) do
    {"PING", []} = Parser.parse(data_str)
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
    if String.length(message_body) != message_body_length do
      Logger.error ":message_body_length_mismatch, #{message_body_length}, #{String.length(message_body)}"
      Process.exit(self(), :message_body_length_mismatch)
    end

    send(subscibers[sid], {:natsex_message, {subject, sid, reply_to}, message_body})

    {:noreply, state}
  end

  def handle_info(:post_init, state) do
    {:ok, data_str} = :gen_tcp.recv(state.socket, 0)
    {"INFO", server_info} = Parser.parse_json_response(data_str)
    Logger.debug("Connected")

    connect_data = %{
      verbose: true, lang: "elixir", name: "natsex",
      version: Application.get_env(:natsex, :version),
      pedantic: true, tls_required: false,
      protocol: 0
    }

    msg = Parser.create_json_command("INFO", %{
      verbose: true, lang: "elixir", name: "natsex",
      version: Application.get_env(:natsex, :version),
      pedantic: true, tls_required: false,
      protocol: 0
    })
    request(msg, state.socket, false)

    msg = Parser.create_message("PING")
    request(msg, state.socket)

    msg = Parser.create_message("SUB", ["telegram.user.notifications", "1"])
    request(msg, state.socket)

    {:noreply, %{state| server_info: server_info}}
  end

  def request(msg, socket, is_wait_response \\ true) do
    Logger.debug "Sending message -> #{inspect msg}"
    :gen_tcp.send(socket, msg)

    if is_wait_response do
      {:ok, data_str} = :gen_tcp.recv(socket, 0)
      Logger.debug "Received response: <- #{inspect data_str}"

      Parser.parse(data_str)
    end
  end

  def read(socket) do
    :gen_tcp.recv(socket, 0)
  end

end
