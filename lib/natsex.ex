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

      # sent a message and waits a response, aka "Request-Reply"
      iex(4)> Natsex.request("questions", "sup?")
      {:ok, "response"}
  """

  @default_connect_timeout 200

  @doc """
  Starts Natsex client process

  ## Examples

      # connects with default params, host - "localhost", port - 4222
      Natsex.start_link
      {:ok, #PID<0.194.0>}

      # connects on custom port with credentials
      Natsex.start_link(%{host: "localhost", port: 4567, user: "admin", pass: "12345"})
      {:ok, #PID<0.195.0>}

      # connects with timeout 2sec
      Natsex.start_link(%{}, 2_000)
      {:ok, #PID<>}

  """
  defdelegate start_link(config \\ nil, connect_timeout \\ @default_connect_timeout),
    to: Natsex.TCPConnector

  @doc """
  Initiates a subscription to a subject.
  When new message will arrive, caller process will receive message:

      {:natsex_message, {subject, sid, nil}, message}

  ## Examples

      sid = Natsex.subscribe("news.urgent", self())
      flush
      {:natsex_message,
       {"telegram.user.notifications", "sub_id", nil},
       "Good news, everyone!"}

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
      :ok
  """
  defdelegate publish(subject, payload \\ "", reply \\ nil), to: Natsex.TCPConnector

  @doc """
  Sending a message and waiting a response, aka "Request-Reply"

  ## Examples

      # wait response with default timeout 1sec
      {:ok, response} = Natsex.request("questions", "sup?")

      # wait response with custom timeout 10sec
      :timeout = Natsex.request("questions", "sup?", 10_000)

  """
  defdelegate request(subject, payload, timeout \\ 1000), to: Natsex.TCPConnector

end
