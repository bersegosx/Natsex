defmodule NatsexTest.TCPConnector do
  use ExUnit.Case

  import ExUnit.CaptureLog

  @max_payload 500
  @reconnect_time_wait 100

  setup context do
    if context[:dont_autostart] == true do
      :ok
    else
      {:ok, mock_pid} = MockServer.start_link
      {:ok, natsex_pid} = Natsex.start_link

      %{mock_pid: mock_pid, natsex_pid: natsex_pid}
    end
  end

  defp conect_client(mock_pid) do
    MockServer.send_data(mock_pid, "INFO {\"auth_required\":false,\"max_payload\":#{@max_payload}} \r\n")
    :timer.sleep(50)
    MockServer.reset_buffer(mock_pid)
  end

  describe "connection" do
    test "command `CONNECT` will send", context do
      %{mock_pid: mock_pid, natsex_pid: natsex_pid} = context

      MockServer.send_data(mock_pid, "INFO {\"auth_required\":false,\"max_payload\":1048576} \r\n")
      :timer.sleep(50)

      natsex_state = :sys.get_state(natsex_pid).mod_state
      server_state = :sys.get_state(mock_pid)

      # Natsex received server info
      assert natsex_state.server_info == %{auth_required: false, max_payload: 1048576}

      # Natsex sent 'connect' message
      assert "CONNECT " <> _ = server_state.buffer
    end

    test "cant receive messages before `INFO` message", context do
      %{mock_pid: mock_pid, natsex_pid: natsex_pid} = context

      publish_func = fn ->
        Natsex.publish(natsex_pid, "123", "", nil, 100)
      end
      assert {:timeout, {:gen_server, :call, _}} = catch_exit(publish_func.())

      MockServer.send_data(mock_pid, "INFO {\"auth_required\":true,\"max_payload\":1048576} \r\n")
      assert publish_func.()
    end

    @tag :dont_autostart
    test "will connect with auth credentials", _context do
      {:ok, mock_pid} = MockServer.start_link
      {login, password} = {"admin", "123"}
      {:ok, natsex_pid} = Natsex.start_link(config: %{user: login, pass: password})

      MockServer.send_data(mock_pid, "INFO {\"auth_required\":true,\"max_payload\":1048576} \r\n")
      :timer.sleep(50)

      natsex_state = :sys.get_state(natsex_pid).mod_state
      server_state = :sys.get_state(mock_pid)

      assert natsex_state.server_info.auth_required
      assert "CONNECT " <> _ = server_state.buffer
      assert server_state.buffer =~ ~s("user":"#{login}") and
             server_state.buffer =~ ~s("pass":"#{password}")
    end

    test "will stop", context do
      %{mock_pid: mock_pid, natsex_pid: natsex_pid} = context
      conect_client(mock_pid)

      assert Natsex.stop(natsex_pid) == :ok
      assert Process.alive?(natsex_pid) == false
    end

    @tag :dont_autostart
    test "will reconnect" do
      {:ok, mock_pid} = MockServer.start_link
      {:ok, natsex_pid} = Natsex.start_link(reconnect_time_wait: @reconnect_time_wait)

      conect_client(mock_pid)

      natsex_state = :sys.get_state(natsex_pid).mod_state
      assert natsex_state.connection == :connected

      # server was stopped
      :ok = GenServer.stop(mock_pid)
      :timer.sleep(50)

      # client state is `:disconnected`
      natsex_state = :sys.get_state(natsex_pid).mod_state
      assert natsex_state.connection == :disconnected

      # server up
      {:ok, mock_pid} = MockServer.start_link
      conect_client(mock_pid)
      :timer.sleep(@reconnect_time_wait + 50)

      natsex_state = :sys.get_state(natsex_pid).mod_state
      assert natsex_state.connection == :connected
    end
  end

  describe "keep_alive" do
    @tag :dont_autostart
    test "will respond on ping", _context do
      {:ok, mock_pid} = MockServer.start_link
      Natsex.start_link
      conect_client(mock_pid)

      MockServer.send_data(mock_pid, "PING\r\n")

      :timer.sleep(50)
      server_state = :sys.get_state(mock_pid)
      assert "PONG\r\n" == server_state.buffer
    end

    @tag :dont_autostart
    test "will send ping", _context do
      {:ok, mock_pid} = MockServer.start_link

      ping_interval = 50
      Natsex.start_link(connect_timeout: 200, ping_interval: ping_interval)
      conect_client(mock_pid)

      # check after `ping_interval`
      :timer.sleep(ping_interval + 50)

      server_state = :sys.get_state(mock_pid)
      assert "PING\r\n" == server_state.buffer
    end

    @tag :dont_autostart
    test "will log if `PONG` didn't receive after timeout", _context do
      {:ok, mock_pid} = MockServer.start_link

      # starts client with new params
      ping_interval = 50
      Natsex.start_link(connect_timeout: 200, ping_interval: ping_interval)
      conect_client(mock_pid)

      pong_receive_timeout = Application.get_env(:natsex, :pong_receive_timeout)
      assert capture_log(fn ->
        :timer.sleep(pong_receive_timeout + 100)
      end) =~ "Server didn't respond on PING command"
    end
  end

  describe "subscribe command" do
    test "will receive message", context do
      %{mock_pid: mock_pid, natsex_pid: natsex_pid} = context
      conect_client(mock_pid)

      subject = "The.X.files"
      sid = Natsex.subscribe(natsex_pid, subject, self())
      :timer.sleep(50)
      server_state = :sys.get_state(mock_pid)

      assert "SUB #{subject} #{sid}\r\n" == server_state.buffer

      message = "myME\r\n$$Age"
      packet = "MSG #{subject} #{sid} #{byte_size(message)}\r\n" <>
               "#{message}\r\n"

      MockServer.send_data(mock_pid, packet)
      assert_receive {:natsex_message, {^subject, ^sid, nil}, ^message}
    end

    test "will monitor client & unsub", context do
      %{mock_pid: mock_pid, natsex_pid: natsex_pid} = context
      conect_client(mock_pid)

      client = spawn(fn ->
        receive do
          x -> x
        end
      end)

      sid = Natsex.subscribe(natsex_pid, "The.X.files", client)
      natsex_state = :sys.get_state(natsex_pid).mod_state
      assert natsex_state.subscribers[sid] == client

      :timer.sleep(50)
      MockServer.reset_buffer(mock_pid)
      :timer.sleep(150)
      send(client, 123)
      :timer.sleep(50)

      natsex_state = :sys.get_state(natsex_pid).mod_state
      server_state = :sys.get_state(mock_pid)

      assert natsex_state.subscribers == %{}
      assert "UNSUB " <> sid <> "\r\n" == server_state.buffer
    end
  end

  describe "publish command" do
    test "will send", context do
      %{mock_pid: mock_pid, natsex_pid: natsex_pid} = context
      conect_client(mock_pid)

      {subject, payload} = {"service.news.out", "breaking news"}
      :ok = Natsex.publish(natsex_pid, subject, payload)
      :timer.sleep(50)
      server_state = :sys.get_state(mock_pid)

      expected = "PUB #{subject} #{String.length(payload)}\r\n" <>
                 "#{payload}\r\n"
      assert server_state.buffer == expected
    end

    test "big message", context do
      %{mock_pid: mock_pid, natsex_pid: natsex_pid} = context
      conect_client(mock_pid)

      {subject, payload} = {"out", String.duplicate("x", @max_payload + 1)}

      assert {:error, "Message is too big (limit: 500, current: 501)"} ==
              Natsex.publish(natsex_pid, subject, payload)
    end
  end

  describe "unsubscribe command" do
    test "will send command", context do
      %{mock_pid: mock_pid, natsex_pid: natsex_pid} = context
      conect_client(mock_pid)

      Natsex.unsubscribe(natsex_pid, "x123x")
      :timer.sleep(50)
      server_state = :sys.get_state(mock_pid)

      expected = "UNSUB x123x\r\n"
      assert server_state.buffer == expected
    end
  end
end
