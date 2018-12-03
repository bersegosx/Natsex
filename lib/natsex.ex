defmodule Natsex do
  @moduledoc """
  Elixir client for NATS.

  ## Examples

      iex(1)>{:ok, pid} = Natsex.start_link
      {:ok, #PID<0.178.0>}

      iex(2)> Natsex.subscribe(pid, "telegram.user.notifications", self())
      "13b2d0cd-9dba-43b6-bb5d-288d48346ff4"

      iex(3)> flush
      {:natsex_message,
       {"telegram.user.notifications", "13b2d0cd-9dba-43b6-bb5d-288d48346ff4", nil},
       "Good news, everyone!"}
      :ok

      # sent a message and waits a response, aka "Request-Reply"
      iex(4)> Natsex.request(pid, "questions", "sup?")
      {:ok, "response"}
  """

  @doc """
  Starts Natsex client process

  ## Options

    - `:config` - Map that contains connection options (auth, host, port, etc)
    - `:connect_timeout` - Timeout for NATS server connection (default: 200 ms)
    - `:ping_interval` - interval for ping/pong  keep-alive mechanism (default: 60_000 ms)
    - `:reconnect_time_wait` - timeout for reconnect (default: 1_000 ms)

  ## Examples

      # connects with default config, host - "localhost", port - 4222
      Natsex.start_link
      {:ok, #PID<0.194.0>}

      # connects on custom port with credentials
      Natsex.start_link(config: %{host: "localhost", port: 4567, user: "admin", pass: "12345"})
      {:ok, #PID<0.195.0>}

      # connects with timeout 2 sec
      Natsex.start_link(connect_timeout: 2_000)
      {:ok, #PID<>}

  """
  defdelegate start_link(opt \\ []), to: Natsex.TCPConnector

  @doc """
  Initiates a subscription to a subject.
  When new message will arrive, caller process will receive message:

      {:natsex_message, {subject, sid, nil}, message}

  ## Examples

      sid = Natsex.subscribe(pid, "news.urgent", self())
      flush
      {:natsex_message,
       {"telegram.user.notifications", "sub_id", nil},
       "Good news, everyone!"}

  """
  defdelegate subscribe(pid, subject, who, sid \\ nil, queue_group \\ nil), to: Natsex.TCPConnector

  @doc """
  Unsubcribes the connection from the specified subject,
  or auto-unsubscribes after the specified number of messages has been received.

  ## Examples

      Natsex.unsubscribe(pid, "13b2d0cd-9dba-43b6-bb5d-288d48346ff4")
      :ok
  """
  defdelegate unsubscribe(pid, sid, max_messages \\ nil), to: Natsex.TCPConnector

  @doc """
  Publishes the message to NATS

  ## Examples

      Natsex.publish(pid, "news.urgent", "today is monday")
      :ok
  """
  defdelegate publish(pid, subject, payload \\ "", reply \\ nil,
                      timeout \\ 5_000), to: Natsex.TCPConnector

  @doc """
  Sending a message and waiting a response, aka "Request-Reply"

  ## Examples

      # wait response with default timeout 1sec
      {:ok, response} = Natsex.request(pid, "questions", "sup?")

      # wait response with custom timeout 10sec
      :timeout = Natsex.request(pid, "questions", "sup?", 10_000)

  """
  defdelegate request(pid, subject, payload, timeout \\ 1000,
                      reply_inbox \\ nil), to: Natsex.TCPConnector

  @doc """
  Stop client
  """
  defdelegate stop(pid), to: Natsex.TCPConnector
end
