defmodule NatsexTest.Parser do
  use ExUnit.Case
  use ExUnit.Parameterized

  alias Natsex.Parser

  test_with_params "parse string",
    fn (input, expected) ->
      assert Parser.parse(input) == expected
    end do
      [
        {"+OK\r\n", {"+OK", []} },
        {"MSG a.b.> sid1 123\r\n", {"MSG", ["a.b.>", "sid1", "123"]} },
        {"-ERR 'Some auth error'\r\n", {"-ERR", ["'Some", "auth", "error'"]} },
      ]
  end

  test "parse json string" do
    input = "INFO {\"version\":\"1.1.0\",\"max_payload\":1048576} \r\n"
    expected = {"INFO", %{version: "1.1.0", max_payload: 1048576}}
    assert Parser.parse_json_response(input) == expected
  end

  test_with_params "create message",
    fn (cmd, opts, expected) ->
      assert Parser.create_message(cmd, opts) == expected
    end do
      [
        {"SUB", ["subject", "qg", "sid1"], "SUB subject qg sid1\r\n"},
        {"SUB", ["subject", nil, "sid1"],  "SUB subject sid1\r\n"},
        {"PONG", [],  "PONG\r\n"},
      ]
  end

  test "create json message" do
    assert Parser.create_json_command("CONNECT", %{user: "q", pass: "word"}) ==
           "CONNECT {\"user\":\"q\",\"pass\":\"word\"}\r\n"
  end

  test_with_params "create publish command",
    fn (subject, reply_to, payload, expected) ->
      assert Parser.command_publish(subject, reply_to, payload) == expected
    end do
      [
        {"service.requests", "inbox.66", "hello nats",
        "PUB SERVICE.REQUESTS inbox.66 10\r\nhello nats\r\n"},

        {"service.requests", nil, "hello nats",
         "PUB SERVICE.REQUESTS 10\r\nhello nats\r\n"},

        {"service.requests", nil, "",
         "PUB SERVICE.REQUESTS 0\r\n\r\n"},
      ]
  end

end
