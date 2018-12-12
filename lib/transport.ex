defmodule Natsex.Transport do
  @moduledoc """
  Transport over tcp|ssl
  """

  require Logger

  def connect(state, config) do
    with {:ok, socket} <- :gen_tcp.connect(to_charlist(config.host), config.port,
                            [:binary, active: false], state.opts.connect_timeout),
         {:ok, info_msg} <- :gen_tcp.recv(socket, 0)
    do
      Logger.debug("<- #{inspect(info_msg)}")

      socket = setops(socket, state)
      state = %{state| socket: socket}
      {server_info, ping_ref} =
        Natsex.TCPConnector.process_info_message(info_msg, state)

      {:ok, %{state| socket: socket, server_info: server_info,
                     ping_timer_ref: ping_ref, connection: :connected}}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  ssl handshake
  """
  def setops(socket, %{config: %{tls_required: true}}) do
    {:ok, ssl_socket} = :ssl.connect(socket, [])
    :ok = :ssl.setopts(ssl_socket, active: :once)
    ssl_socket
  end
  def setops(socket, _state) do
    :ok = :inet.setopts(socket, active: :once)
    socket
  end

  def send_to_server(%{socket: socket} = state, msg) do
    if state.config.tls_required do
      :ssl.send(socket, msg)
    else
      :gen_tcp.send(socket, msg)
    end

    Logger.debug("-> #{inspect msg}")
  end
end
