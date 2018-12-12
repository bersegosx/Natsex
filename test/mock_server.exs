defmodule MockServer do
  use GenServer

  @cert "./test/cert/Nats.crt"
  @cert_key "./test/cert/Nats.key"

  def send_data(pid, data) do
    GenServer.cast(pid, {:send, data})
  end

  def reset_buffer(pid) do
    GenServer.cast(pid, :reset_buffer)
  end

  def enable_tls(pid) do
    GenServer.cast(pid, :enable_tls)
  end

  def start_link do
    GenServer.start_link(__MODULE__, :ok)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  def init(_) do
    port = 4222
    {:ok, listen_socket}= :gen_tcp.listen(port,
      [:binary, packet: 0, active: true, reuseaddr: true]
    )

    send(self(), :post_init)

    {:ok, %{listen_socket: listen_socket, buffer: ""}}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_cast(:enable_tls, state) do
    IO.inspect "enable_tls", label: "cmd"
    :inet.setopts(state.socket, active: false)

    {:ok, ssl_socket} = ssl_handshake(state.socket, [
      certfile: Path.expand(@cert),
      keyfile: Path.expand(@cert_key)
    ], 1_000)

    :ok = :ssl.setopts(ssl_socket, active: true)

    {:noreply, %{state| socket: ssl_socket}}
  end

  def handle_cast({:send, data}, state) do
    IO.inspect(data, label: "->")
    :gen_tcp.send(state.socket, data)
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
