defmodule Natsex.Validator do
  @moduledoc """
  Subject/Reply_Subject names validator
  """

  @spec is_valid(String.t, boolean()) :: :ok | String.t
  @spec is_valid(String.t) :: :ok | String.t
  def is_valid(v, accept_nil) do
    if accept_nil and v == nil do
      :ok
    else
      is_valid(v)
    end
  end
  def is_valid(v) do
    cond do
      v == nil ->
        "`nil` value isn't allowed"

      v == "" ->
        "Empty string isn't allowed"

      v == "." ->
        "Single '.' isn't allowed"

      v =~ " " ->
        "Whitespace isn't allowed"

      v =~ ".." ->
        "Double '.' isn't allowed"

      String.starts_with?(v, ".") || String.ends_with?(v, ".") ->
        "Can't starts/ends with '.' char"

      true ->
        :ok
    end
  end
end
