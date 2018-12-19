defmodule MockServer do
  use GenServer

  @cert "./test/cert/Nats.crt"
  @cert_key "./test/cert/Nats.key"
  @cert_ca "./test/cert/SelfCA.crt"

  def send_data(pid, data) do
    GenServer.cast(pid, {:send, data})
  end

  def reset_buffer(pid) do
    GenServer.cast(pid, :reset_buffer)
  end

  def enable_tls(pid, verify_client_cert \\ false) do
    GenServer.call(pid, {:enable_tls, verify_client_cert})
  end

  def start_link do
    GenServer.start_link(__MODULE__, :ok)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  def init(_) do
    {:ok, listen_socket}= :gen_tcp.listen(4222,
      [:binary, packet: 0, active: true, reuseaddr: true]
    )

    send(self(), :post_init)

    {:ok, %{listen_socket: listen_socket, buffer: "", tls: false}}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:enable_tls, verify_client_cert}, _from, state) do
    IO.inspect "enable_tls", label: "cmd"
    :inet.setopts(state.socket, active: false)

    ssl_opts = [
      certfile: Path.expand(@cert),
      keyfile: Path.expand(@cert_key),
      cacertfile: Path.expand(@cert_ca)
    ]

    ssl_opts =
      if verify_client_cert do
        Keyword.merge(ssl_opts, [verify: :verify_peer, fail_if_no_peer_cert: true])
      else
        ssl_opts
      end

    {reply, socket} =
      with {:ok, ssl_socket} <- ssl_handshake(state.socket, ssl_opts, 1_000),
           :ok <- :ssl.setopts(ssl_socket, active: true)
      do
        {:ok, ssl_socket}
      else
        err -> {err, nil}
      end

    {:reply, reply, %{state| socket: socket, tls: true}}
  end

  def handle_cast({:send, data}, state) do
    IO.inspect(data, label: "->")

    m = if state.tls, do: :ssl, else: :gen_tcp
    apply(m, :send, [state.socket, data])

    {:noreply, state}
  end

  def handle_cast(:reset_buffer, state) do
    IO.inspect "reset_buffer", label: "cmd"
    {:noreply, %{state| buffer: ""}}
  end

  def handle_info(:post_init, state) do
    {:ok, socket} = :gen_tcp.accept(state.listen_socket)
    {:noreply, Map.put(state, :socket, socket)}
  end

  def handle_info({:tcp, _socket, packet}, state) do
    IO.inspect packet, label: "<-"
    {:noreply, %{state| buffer: state.buffer <> packet}}
  end

  def handle_info({:ssl, socket, packet}, state) do
    handle_info({:tcp, socket, packet}, state)
  end

  def handle_info({:tcp_closed, _socket},state) do
    IO.inspect "Socket has been closed"
    {:noreply, state}
  end

  def handle_info({:ssl_closed, socket},state) do
    handle_info({:tcp_closed, socket},state)
  end

  def handle_info({:tcp_error, socket, reason},state) do
    IO.inspect socket, label: "connection closed dut to #{reason}"
    {:noreply, state}
  end

  def handle_info(what, state) do
    IO.inspect what, label: "handle_info: mock_server"
    {:noreply, state}
  end

  defp ssl_handshake(socket, opts, timeout) do
    if function_exported?(:ssl, :handshake, 3) do
      apply(:ssl, :handshake, [socket, opts, timeout])
    else
      apply(:ssl, :ssl_accept, [socket, opts, timeout])
    end
  end
end
