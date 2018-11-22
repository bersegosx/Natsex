defmodule Natsex do
  @moduledoc """
  Elixir client for NATS.

  ## Examples

      iex(1)> Natsex.start_link
      {:ok, #PID<0.178.0>}
      iex(2)> Natsex.subscribe "telegram.user.notifications", self
      "13b2d0cd-9dba-43b6-bb5d-288d48346ff4"
      iex(3)> flush
      {:natsex_message,
       {"telegram.user.notifications", "13b2d0cd-9dba-43b6-bb5d-288d48346ff4", nil},
       "Good news, everyone!"}
      :ok
      iex(4)>

  """

  @doc """
  Starts Natsex client process
  """
  defdelegate start_link, to: Natsex.TCPConnector

  @doc """
  Initiates a subscription to a subject.
  When new message will arrive, caller process will receive message:

      {:natsex_message, {subject, sid, nil}, message}

  ## Examples

      sid = Natsex.subscribe("news.urgent", self())
      flush
      {:natsex_message,
       {"telegram.user.notifications", "sub_id", nil},
       "\"Good news, everyone!\""}

  """
  defdelegate subscribe(subject, who, sid \\ nil, queue_group \\ nil), to: Natsex.TCPConnector

  @doc """
  Unsubcribes the connection from the specified subject,
  or auto-unsubscribes after the specified number of messages has been received.

  ## Examples

      Natsex.unsubscribe "13b2d0cd-9dba-43b6-bb5d-288d48346ff4"
      :ok
  """
  defdelegate unsubscribe(sid, max_messages \\ nil), to: Natsex.TCPConnector

  @doc """
  Publishes the message to NATS

  ## Examples

      Natsex.publish("news.urgent", "today is monday")

  """
  defdelegate publish(subject, payload \\ "", reply \\ nil), to: Natsex.TCPConnector

end
