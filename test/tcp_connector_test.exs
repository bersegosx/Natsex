defmodule NatsexTest.TCPConnector do
  use ExUnit.Case

  setup do
    {:ok, pid} = MockServer.start_link
    Natsex.start_link

    %{mock_pid: pid}
  end

  defp conect_client(mock_pid) do
    MockServer.send_data(mock_pid, "INFO {\"auth_required\":false,\"max_payload\":1048576} \r\n")
    :timer.sleep(50)
    MockServer.reset_buffer(mock_pid)
  end

  test "connect to nats", context do
    mock_pid = context.mock_pid

    # before connection `server_info` is empty
    natsex_state = Natsex.TCPConnector.get_state()
    assert natsex_state.server_info == nil

    MockServer.send_data(mock_pid, "INFO {\"auth_required\":false,\"max_payload\":1048576} \r\n")
    :timer.sleep(200)
    natsex_state = Natsex.TCPConnector.get_state()
    server_state = MockServer.get_state(mock_pid)

    # Natsex received server info
    assert natsex_state.server_info == %{auth_required: false, max_payload: 1048576}

    # Natsex sent 'connect' message
    assert "CONNECT " <> _ = server_state.buffer
  end

  test "will respond on ping", context do
    mock_pid = context.mock_pid
    conect_client(mock_pid)

    MockServer.send_data(mock_pid, "PING\r\n")

    :timer.sleep(50)
    server_state = MockServer.get_state(mock_pid)
    assert "PONG\r\n" == server_state.buffer
  end

  test "subscribe command", context do
    mock_pid = context.mock_pid
    conect_client(mock_pid)

    subject = "The.X.files"
    sid = Natsex.subscribe(subject, self())
    :timer.sleep(50)
    server_state = MockServer.get_state(mock_pid)

    assert "SUB #{subject} #{sid}\r\n" == server_state.buffer

    message = "myME\r\n$$Age"
    packet = "MSG #{subject} #{sid} #{byte_size(message)}\r\n" <>
             "#{message}\r\n"

    MockServer.send_data(mock_pid, packet)
    assert_receive {:natsex_message, {^subject, ^sid, nil}, ^message}
  end

  test "publish command", context do
    mock_pid = context.mock_pid
    conect_client(mock_pid)

    {subject, payload} = {"service.news.out", "breaking news"}
    _sid = Natsex.publish(subject, payload)
    :timer.sleep(50)
    server_state = MockServer.get_state(mock_pid)

    expected = "PUB #{String.upcase(subject)} #{String.length(payload)}\r\n" <>
               "#{payload}\r\n"
    assert server_state.buffer == expected
  end

end
