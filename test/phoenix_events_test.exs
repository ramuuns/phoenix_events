defmodule PhoenixEventsTest do
  use ExUnit.Case
  doctest PhoenixEvents

  import ExUnit.CaptureLog

  test "PhoenixEvents starts and registers itself in the process registry" do
    children = [
      %{
        id: PhoenixEvents,
        start:
          {PhoenixEvents, :start_link,
           [%{persona: "test", log_queries: true, queries_prefix: [:fake, :repo]}, []]}
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one)

    # other_pid = Process.whereis(:phoenix_events_instance)
    # assert pid == other_pid

    log =
      capture_log(fn ->
        PhoenixEvents.Event.wrap_in_event("request", "action", fn ->
          PhoenixEvents.Event.maybe_add_volatile(:some_key, "some_value")
        end)
      end)

    # log |> IO.puts
    assert log =~ "action: \"action\""
    assert log =~ "persona: \"test\""
    assert log =~ "the_request: \"request\""
    assert log =~ "some_key: \"some_value\""

    log =
      capture_log(fn ->
        PhoenixEvents.Event.wrap_in_event("lol hey", "action", fn ->
          :telemetry.execute([:fake, :repo, :query], %{total_time: 5 * 1_000_000}, %{
            query: "SELECT blah FROM test WHERE 1 = 1"
          })
        end)
      end)

    assert log =~ "nr_queries: 1"
    assert log =~ "wallclock_queries: 5"
    assert log =~ "queries: [[5, \"SELECT blah FROM test WHERE 1 = 1\"]"

    ["one", "two"]
    |> Task.async_stream(fn val ->
      {val,
       capture_log(fn ->
         PhoenixEvents.Event.wrap_in_event("request_" <> val, "action", fn ->
           PhoenixEvents.Event.maybe_add_volatile(:some_key, val)
         end)
       end)}
    end)
    |> Enum.each(fn {_, {val, log}} ->
      assert log =~ "the_request: \"request_#{val}\""
      assert log =~ "some_key: \"#{val}\""
    end)
  end
end
