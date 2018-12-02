defmodule Natsex.MixProject do
  use Mix.Project

  def project do
    [
      app: :natsex,
      version: "0.7.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      package: package(),
      description: description(),
      name: "Natsex",
      source_url: "https://github.com/bersegosx/Natsex",

      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: ["coveralls": :test],

      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:poison, "~> 3.1"},
      {:uuid, "~> 1.1"},
      {:connection, "~> 1.0"},

      {:ex_doc, "~> 0.18.0", only: :dev, runtime: false},
      {:ex_parameterized, "~> 1.3.2", only: :test},
      {:excoveralls, "~> 0.10", only: :test},
    ]
  end

  defp description() do
    "Client for NATS"
  end

  defp package() do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/bersegosx/Natsex"}
    ]
  end
end
