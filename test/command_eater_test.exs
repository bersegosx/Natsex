defmodule NatsexTest.CommandEater do
  use ExUnit.Case, async: true
  use ExUnit.Parameterized

  alias Natsex.CommandEater

  test_with_params "feed",
    fn (input, expected) ->
      assert CommandEater.feed(input) == expected
    end do
      [
        {"+OK", {"+OK", []} },
        {"+OK\r", {"+OK\r", []} },
        {"+OK\r\nfoo", {"foo", ["+OK"]} },
        {
          "+OK\r\nPING\r\nPONG\r\nMSG ",
          {"MSG ", ["+OK", "PING", "PONG"]}
        },
        {
          "PING\r\nMSG sxs 3\r\n123\r\nPONG\r\nx ",
          {"x ", ["PING", {"MSG sxs 3", "123"}, "PONG"]}
        },
      ]
  end

end
