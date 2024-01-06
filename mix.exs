defmodule PhoenixEvents.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_events,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:credo, ">= 0.0.0", only: :dev, github: "rrrene/credo"},
      {:phoenix, ">= 0.0.0"},
      {:jason, ">= 0.0.0"},
      {:telemetry, ">= 0.0.0"}
    ]
  end
end
