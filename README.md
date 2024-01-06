# PhoenixEvents

A library that allows capturing http requests, websocket "actions" and other custom "events" (think cron-like stuff),
into a structured data and (optionally) sends them to an [eventcollector](https://github.com/ramuuns/eventcollector) instance




## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `phoenix_events` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_events, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/phoenix_events>.

