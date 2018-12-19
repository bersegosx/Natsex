defmodule NatsexTest.ServerInfo do
  use ExUnit.Case, async: true

  alias Natsex.ServerInfo

  describe "parse" do
    test "user:password" do
        assert ServerInfo.parse("nats://user:password@server:80") ==
          {"server", 80, "user", "password", nil}
    end

    test "token" do
        assert ServerInfo.parse("nats://tokenizeme@manylance.com:7890") ==
          {"manylance.com", 7890, nil, nil, "tokenizeme"}
    end
  end
end
