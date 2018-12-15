# copied from https://github.com/mmmries/gnat/blob/master/bench.exs

defmodule EchoServer do
  def run(natsex_pid) do
    spawn(fn -> init(natsex_pid) end)
  end

  def init(natsex_pid) do
    Natsex.subscribe(natsex_pid, "echo", self())
    loop(natsex_pid)
  end

  def loop(natsex_pid) do
    receive do
      {:natsex_message, {_subj, _sid, reply_to}, _msg} ->
        Natsex.publish(natsex_pid, reply_to, "pong")
      other ->
        IO.puts "server received: #{inspect other}"
    end

    loop(natsex_pid)
  end
end

msg128 = "74c93e71c5aa03ad4f0881caa374ba1af08f3e4a04ce5f8bd0b2d82d6d72de6eef3e46ed8d8c3dbe24d0f6109115dcdf13280d1c13c2f6d22d14336b29df8e65"
msg16 = "74c93e71c5aa03ad"
tcp_packet = "MSG topic 1 128\r\n#{msg128}\r\n"

{:ok, pid} = Natsex.start_link
EchoServer.run(pid)

Benchee.run(
  %{
    "request/reply" => fn ->
      {:ok, "pong"} = Natsex.request(pid, "echo", "ping")
    end,
    "pub - 128" => fn ->
      :ok = Natsex.publish(pid, "pub128", msg128)
    end,
    "parse-128" => fn ->
      {_, _} = Natsex.CommandEater.feed(tcp_packet)
    end,
    "sub-unsub-pub-16" => fn ->
      rand = :crypto.strong_rand_bytes(8) |> Base.encode64
      subscription = Natsex.subscribe(pid, rand, self())
      Natsex.unsubscribe(pid, subscription, 1)
      :ok = Natsex.publish(pid, rand, msg16)

      receive do
        {:natsex_message, {^rand, ^subscription, _}, ^msg16} ->
          :ok
      after 100 ->
        raise "timed out on sub"
      end
    end,
  },
  time: 10, warmup: 2
)
