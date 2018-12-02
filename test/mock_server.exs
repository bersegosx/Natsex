defmodule MockServer do
  use GenServer

  def send_data(pid, data) do
    GenServer.cast(pid, {:send, data})
  end

  def reset_buffer(pid) do
    GenServer.cast(pid, :reset_buffer)
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

  def handle_info({:tcp_closed, _socket},state) do
    IO.inspect "Socket has been closed"
    {:noreply, state}
  end

  def handle_info({:tcp_error, socket, reason},state) do
    IO.inspect socket, label: "connection closed dut to #{reason}"
    {:noreply, state}
  end
end
