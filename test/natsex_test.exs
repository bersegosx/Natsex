defmodule NatsexTest do
  use ExUnit.Case
  doctest Natsex

  test "greets the world" do
    assert Natsex.hello() == :world
  end
end
