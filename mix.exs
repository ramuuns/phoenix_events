defmodule PhoenixEvents.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_events,
      version: "0.5.1",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      name: "Phoenix events",
      source_url: "https://github.com/ramuuns/phoenix_events",
      package: package()
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
      {:telemetry, ">= 0.0.0"},
      {:req, "~> 0.4.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp description() do
    """
    A library that allows capturing http requests, websocket "actions", oban job executions and other custom "events" (think cron-like stuff),
    into a structured data and (optionally) sends them to an [eventcollector](https://github.com/ramuuns/eventcollector) instance
    """
  end

  defp package() do
    [
      licenses: ["MIT"],
      links: %{GitHub: "https://github.com/ramuuns/phoenix_events"}
    ]
  end
end
