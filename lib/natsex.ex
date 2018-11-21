defmodule Natsex do
  @moduledoc """
  Elixir client for NATS.
  """

  @doc """


  ## Examples

      iex> Natsex.hello
      :world

  """

  defdelegate start_link, to: Natsex.TCPConnector
  defdelegate subscribe(subject, who, sid \\ nil, queue_group \\ nil), to: Natsex.TCPConnector
  defdelegate unsubscribe(sid, max_messages \\ nil), to: Natsex.TCPConnector
  defdelegate publish(subject, payload \\ "", reply \\ nil), to: Natsex.TCPConnector

end
