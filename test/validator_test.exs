defmodule NatsexTest.Validator do
  use ExUnit.Case
  use ExUnit.Parameterized

  test_with_params "is_valid",
    fn (input, expected) ->
      assert Natsex.Validator.is_valid(input) == expected
    end do
      [
        {"as.d", :ok},
        {"AbcD", :ok},
        {".B.c", "Can't starts/ends with '.' char"},
        {"B.c.", "Can't starts/ends with '.' char"},
        {"B. c", "Whitespace isn't allowed"},
        {"", "Empty string isn't allowed"},
        {".", "Single '.' isn't allowed"},
        {"A..c", "Double '.' isn't allowed"},
        {"", "Empty string isn't allowed"},
        {"成田.for.боярышник", "Must contains only ascii alphanumeric string"},
      ]
  end

  test "is_valid with nil" do
    assert Natsex.Validator.is_valid(nil, true) == :ok
  end

  test "is_valid with param" do
    assert Natsex.Validator.is_valid(nil, true) == :ok
  end
end
