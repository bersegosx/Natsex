defmodule Natsex.Parser do
  @moduledoc """
  NATS protocol parser/serializer
  """
  require Logger

  @message_end "\r\n"

  @typep parsed_command :: {String.t, [String.t]}

  @spec parse(String.t) :: parsed_command
  def parse(message) do
    [command|params] = String.split(message, " ")
    {command, params}
  end

  @spec parse_json_response(String.t) :: parsed_command
  def parse_json_response(message) do
    {command, data_json_str} = parse(message)
    data = Poison.decode!(data_json_str, keys: :atoms)
    {command, data}
  end

  @spec command_publish(String.t, String.t | nil, any) :: String.t
  def command_publish(subject, reply_to, payload) do
    create_message("PUB", [subject, reply_to, byte_size(payload)]) <>
    create_message(payload)
  end

  @spec create_json_command(String.t, map()) :: String.t
  def create_json_command(command, data) do
    create_message(command, [Poison.encode!(data)])
  end

  @spec create_message(String.t, list()) :: String.t
  def create_message(command, params \\ []) do
    params_str =
      params
      |> Enum.filter(fn x -> x end)
      |> Enum.join(" ")

    params_str = if params_str != "", do: " " <> params_str, else: ""
    "#{command}#{params_str}#{@message_end}"
  end
end
