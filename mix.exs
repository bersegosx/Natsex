defmodule Natsex.MixProject do
  use Mix.Project

  def project do
    [
      app: :natsex,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      package: package(),
      description: description(),
      name: "Natsex",
      source_url: "https://github.com/bersegosx/Natsex"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:poison, "~> 3.1"},
      {:uuid, "~> 1.1"},

      {:ex_doc, "~> 0.18.0", only: :dev, runtime: false},
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
