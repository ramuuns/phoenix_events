defmodule PhoenixEvents.Event do
  use GenServer
  require Logger

  @impl true
  def init(%{
        persona: persona,
        the_request: the_request
      }) do
    {:ok,
     %{
       start: :os.system_time(:millisecond),
       finalized: false,
       sent: false,
       event: %{
         epoch: :os.system_time(:seconds),
         id: make_id(),
         persona: persona,
         tuning: %{
           nr_errors: 0,
           nr_warnings: 0,
           nr_queries: 0,
           wallclock_queries: 0,
           errors: [],
           unique_warnings: %{},
           the_request: the_request
         },
         volatile: %{
           queries: []
         }
       }
     }}
  end

  def cleanup(pid) do
    GenServer.stop(pid, :normal)
  end

  def finalize(pid) do
    GenServer.call(pid, :finalize)
  end

  def send(pid, options) do
    GenServer.call(pid, {:send, options})
  end

  def set_action(pid, action) do
    GenServer.cast(
      pid,
      {:set_action,
       action |> to_string() |> String.replace(".", "-") |> String.replace(~r"^Elixir-", "")}
    )
  end

  def add_error(pid, error) do
    GenServer.cast(pid, {:add_error, error})
  end

  def add_warning(pid, warning) do
    GenServer.cast(pid, {:add_warning, warning})
  end

  def add_query(pid, query) do
    GenServer.cast(pid, {:add_query, query})
  end

  def maybe_add_volatile(key, value) do
    event_pid = PhoenixEvents.pid_to_event(self())

    if event_pid != nil do
      add_volatile(event_pid, key, value)
    end
  end

  def add_volatile(pid, key, value) do
    GenServer.cast(pid, {:add_volatile, {key, value}})
  end

  def start_link(data) do
    GenServer.start_link(__MODULE__, data, [])
  end

  def setup(pid, setup_func, params) do
    GenServer.cast(pid, {:setup, setup_func, params})
  end

  @impl true
  def handle_cast({:setup, setup_func, setup_func_params}, %{event: event} = data) do
    {:noreply, %{data | event: apply(setup_func, [event] ++ setup_func_params)}}
  end

  @impl true
  def handle_cast({:set_action, action}, %{event: ev} = event) do
    {:noreply, %{event | event: ev |> Map.put(:action, action)}}
  end

  @impl true
  def handle_cast({:add_error, error}, %{event: %{tuning: tuning} = ev} = event) do
    {:noreply,
     %{
       event
       | event: %{
           ev
           | tuning: %{tuning | nr_errors: tuning.nr_errors + 1, errors: [error | tuning.errors]}
         }
     }}
  end

  @impl true
  def handle_cast({:add_warning, warning}, %{event: %{tuning: tuning} = ev} = event) do
    {:noreply,
     %{
       event
       | event: %{
           ev
           | tuning: %{
               tuning
               | nr_warnings: tuning.nr_warnings + 1,
                 unique_warnings:
                   tuning.unique_warnings
                   |> Map.put(warning, Map.get(tuning.unique_warnings, warning, 0) + 1)
             }
         }
     }}
  end

  @impl true
  def handle_cast(
        {:add_query, {query, wallclock}},
        %{event: %{tuning: tuning, volatile: volatile} = ev} = event
      ) do
    tuning = %{
      tuning
      | nr_queries: tuning.nr_queries + 1,
        wallclock_queries: tuning.wallclock_queries + wallclock
    }

    volatile = %{
      volatile
      | queries: [[wallclock, query] | volatile.queries]
    }

    {:noreply, %{event | event: %{ev | tuning: tuning, volatile: volatile}}}
  end

  def handle_cast({:add_volatile, {key, value}}, %{event: %{volatile: volatile} = ev} = event) do
    volatile = volatile |> Map.put(key, value)
    {:noreply, %{event | event: %{ev | volatile: volatile}}}
  end

  @impl true
  def handle_call(:finalize, _from, %{finalized: true} = event), do: {:reply, :ok, event}

  @impl true
  def handle_call(:finalize, _from, event) do
    duration = :os.system_time(:millisecond) - event.start

    tuning =
      event.event.tuning
      |> Map.put(:wallclock_ms, duration)

    volatile = event.event.volatile
    v_queries = volatile.queries |> Enum.reverse()
    volatile = %{volatile | queries: v_queries}

    {:reply, :ok,
     %{
       event
       | finalized: true,
         event: Map.put(event.event, :tuning, tuning) |> Map.put(:volatile, volatile)
     }}
  end

  @impl true
  def handle_call({:send, _}, _from, %{sent: true} = event), do: {:reply, :ok, event}
  @impl true
  def handle_call({:send, options}, from, %{finalized: false} = event) do
    {_, _, event} = handle_call(:finalize, from, event)
    handle_call({:send, options}, from, event)
  end

  def handle_call({:send, options}, _from, event) do
    if options.log_events do
      Logger.info(event.event |> inspect(pretty: true))
    end

    if options.send_events do
      event_json = Jason.encode!(event.event)
      send_event(event_json, options)
    end

    {:reply, :ok, %{event | sent: true}}
  end

  defp send_event(json, options) do
    port = options.collector_port
    host = options.collector_host

    Task.async(fn ->
      :httpc.request(
        :post,
        {~c"http://#{host}:#{port}/event", [], ~c"application/json", json |> to_charlist()},
        [],
        []
      )
    end)
  end

  defp make_id() do
    binary = <<
      System.system_time(:nanosecond)::64,
      :erlang.phash2({node(), self()}, 16_777_216)::24,
      :erlang.unique_integer()::32
    >>

    Base.url_encode64(binary)
  end

  def wrap_in_event(the_request, action, callback) do
    event_meta = %{
      action: action,
      the_request: the_request,
      pid: self()
    }

    :telemetry.execute([:phoenix_events, :event, :start], %{}, event_meta)

    ret = callback.()

    :telemetry.execute([:phoenix_events, :event, :stop], %{}, event_meta)
    ret
  end
end
