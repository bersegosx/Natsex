defmodule Natsex.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Natsex.TCPConnector, %{
        host: "localhost",
        port: 4222,
      }},
    ]

    opts = [strategy: :one_for_one, name: Natsex.Application.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
