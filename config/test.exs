use Mix.Config

config :natsex,
  pong_receive_timeout: 200

config :logger,
  level: :info,
  backends: [:console]
