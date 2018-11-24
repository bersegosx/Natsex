defmodule NatsexTest.Parser do
  use ExUnit.Case, async: true
  use ExUnit.Parameterized

  alias Natsex.Parser

  describe "parse" do
    test_with_params "string",
      fn (input, expected) ->
        assert Parser.parse(input) == expected
      end do
        [
          {"+OK", {"+OK", []} },
          {"MSG a.b.> sid1 123\r\n", {"MSG", ["a.b.>", "sid1", "123\r\n"]} },
          {"-ERR 'Some auth error'", {"-ERR", ["'Some", "auth", "error'"]} },
        ]
    end

    test "json string" do
      input = "INFO {\"version\":\"1.1.0\",\"max_payload\":1048576} \r\n"
      expected = {"INFO", %{version: "1.1.0", max_payload: 1048576}}
      assert Parser.parse_json_response(input) == expected
    end
  end

  describe "create" do
    test_with_params "command",
      fn (cmd, opts, expected) ->
        assert Parser.create_message(cmd, opts) == expected
      end do
        [
          {"SUB", ["subject", "qg", "sid1"], "SUB subject qg sid1\r\n"},
          {"SUB", ["subject", nil, "sid1"],  "SUB subject sid1\r\n"},
          {"PONG", [],  "PONG\r\n"},
        ]
    end

    test "json command" do
      assert Parser.create_json_command("CONNECT", %{user: "q", pass: "word"}) ==
             "CONNECT {\"user\":\"q\",\"pass\":\"word\"}\r\n"
    end

    test_with_params "publish command",
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

          {"service.requests", nil, "123\r\n5",
           "PUB SERVICE.REQUESTS 6\r\n123\r\n5\r\n"},
        ]
    end
  end
end
