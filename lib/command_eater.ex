defmodule Natsex.CommandEater do
  @moduledoc """
  Splits incoming buffer into commands
  """
  
  @message_end "\r\n"
  @word_commands ~w(+OK PING PONG)
  @line_commands ["INFO ", "-ERR ", "PUB ", "SUB "]

  def feed(buffer, commands \\ []) do
    case eat(buffer) do
      {"", ^buffer} ->
        {buffer, Enum.reverse(commands)}

      {cmd, rest_buffer} ->
        feed(rest_buffer, [cmd | commands])
    end
  end

  defp eat("MSG " <> tail = buffer) do
    if tail =~ @message_end do
      [cmd_line, rest] = String.split(buffer, @message_end, parts: 2)

      {message_length, ""} =
        String.split(cmd_line, " ")
        |> Enum.at(-1)
        |> Integer.parse(10)

      case rest do
        <<msg::binary-size(message_length), "\r\n", tail_buffer::binary>> ->
          {{cmd_line, msg}, tail_buffer}

        _ ->
          {"", buffer}
      end
    else
      {"", buffer}
    end
  end

  defp eat(buffer) do
    if String.starts_with?(buffer, @word_commands ++ @line_commands) and
       buffer =~ @message_end do

      String.split(buffer, @message_end, parts: 2)
      |> List.to_tuple
    else
      {"", buffer}
    end
  end
end
