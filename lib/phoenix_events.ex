defmodule PhoenixEvents do
  use GenServer

  alias PhoenixEvents.Event

  @instance_name :phoenix_events_instance

  @defaults %{
    log_queries: false,
    log_live_view: false,
    live_view_prefix: [:phoenix, :live_view],
    log_http: true,
    http_prefix: [:phoenix, :endpoint],
    send_events: false,
    log_events: true
  }

  @impl true
  def init(options) when is_map(options) do
    options = Map.merge(@defaults, options)

    validate_options(options)

    if options.log_live_view do
      :telemetry.attach(
        "websocket-events-mount-start",
        options.live_view_prefix ++ [:mount, :start],
        &PhoenixEvents.ws_event/4,
        {self()}
      )

      :telemetry.attach(
        "websocket-events-hp-start",
        options.live_view_prefix ++ [:handle_params, :start],
        &PhoenixEvents.ws_event/4,
        {self()}
      )

      :telemetry.attach(
        "websocket-events-hp-end",
        options.live_view_prefix ++ [:handle_params, :stop],
        &PhoenixEvents.ws_event/4,
        {self()}
      )

      :telemetry.attach(
        "websocket-events-he-start",
        options.live_view_prefix ++ [:handle_event, :start],
        &PhoenixEvents.ws_event/4,
        {self()}
      )

      :telemetry.attach(
        "websocket-events-he-end",
        options.live_view_prefix ++ [:handle_event, :stop],
        &PhoenixEvents.ws_event/4,
        {self()}
      )
    end

    if options.log_http do
      :telemetry.attach(
        "http-event-start",
        options.http_prefix ++ [:start],
        &PhoenixEvents.http_event/4,
        {self()}
      )

      :telemetry.attach(
        "http-event-end",
        options.http_prefix ++ [:stop],
        &PhoenixEvents.http_event/4,
        {self()}
      )
    end

    if options.log_queries do
      if not Map.has_key?(options, :queries_prefix) do
        raise "PhoenixEvents: log_queries option is set to true, but the :queries_prefix option is missing"
      end

      if not is_list(options.queries_prefix) do
        raise "PhoenixEvents: :queries_prefix option must be a list, e.g. [:myapp, :repo]"
      end

      :telemetry.attach(
        "queries",
        options.queries_prefix ++ [:query],
        &PhoenixEvents.handle_query/4,
        {self()}
      )
    end

    :telemetry.attach(
      "phoenix-custom-event-start",
      [:phoenix_events, :event, :start],
      &PhoenixEvents.custom_event/4,
      {self()}
    )

    :telemetry.attach(
      "phoenix-custom-event-end",
      [:phoenix_events, :event, :stop],
      &PhoenixEvents.custom_event/4,
      {self()}
    )

    Process.register(self(), @instance_name)

    {:ok, {%{}, %{}, options}}
  end

  defp validate_options(options) do
    if !Map.has_key?(options, :persona) do
      raise "PhoenixEvents: persona option must be defined! (this will identify the events as coming from your application)"
    end

    if !is_binary(options.persona) do
      raise "PhoenixEvents: the persona option must be a string"
    end

    if options.send_events and not Map.has_key?(options, :collector_host) do
      raise "PhoenixEvents: option send_events is true, but :collector_host is not defined"
    end

    if options.send_events and not Map.has_key?(options, :collector_port) do
      raise "PhoenixEvents: option send_events is true, but :collector_port is not defined"
    end
  end

  def start_link(settings, opts) do
    GenServer.start_link(__MODULE__, settings, opts)
  end

  def ws_event(name, measurements, %{socket: %{transport_pid: t}} = meta, {pid}) when t != nil do
    [name | _] = name |> Enum.reverse()
    GenServer.call(pid, {:ws_event, [name], measurements, meta})
  end

  def ws_event(_, _, _, _), do: :ok

  def http_event(name, measurements, meta, {pid}) do
    [name | _] = name |> Enum.reverse()
    GenServer.call(pid, {:http_event, [name], measurements, meta})
  end

  def custom_event([_, _, name], measurements, meta, {pid}) do
    GenServer.call(pid, {:custom_event, [name], measurements, meta})
  end

  def handle_query(_, measurements, meta, {phoenix_events_pid}) do
    event_pid = PhoenixEvents.pid_to_event(phoenix_events_pid, self())

    if event_pid != nil do
      Event.add_query(event_pid, {meta.query, div(measurements.total_time, 1_000_000)})
    end
  end

  @impl true
  def handle_call(
        {:http_event, [:start], _measurements, meta},
        _from,
        {events, processes, options}
      ) do
    pid = make_http_event(meta.conn, options)

    events = events |> Map.put(meta.conn.owner, pid)
    ref = Process.monitor(meta.conn.owner)
    processes = processes |> Map.put(meta.conn.owner, ref)

    {:reply, :ok, {events, processes, options}}
  end

  @impl true
  def handle_call(
        {:http_event, [:stop], _measurements, meta},
        _from,
        {events, processes, options}
      ) do
    {event_pid, events} = events |> Map.pop(meta.conn.owner)
    {ref, processes} = processes |> Map.pop(meta.conn.owner)
    Process.demonitor(ref)
    Event.finalize(event_pid)
    Event.send(event_pid, options)
    Event.cleanup(event_pid)

    {:reply, :ok, {events, processes, options}}
  end

  @impl true
  def handle_call(
        {:custom_event, [:start], _measurements, meta},
        _from,
        {events, processes, options}
      ) do
    {:ok, pid} =
      Event.start_link(%{
        persona: options.persona,
        the_request: meta.the_request
      })

    Event.set_action(pid, meta.action)

    events = events |> Map.put(meta.pid, pid)
    ref = Process.monitor(meta.pid)
    processes = processes |> Map.put(meta.pid, ref)

    {:reply, :ok, {events, processes, options}}
  end

  @impl true
  def handle_call(
        {:custom_event, [:stop], _measurements, meta},
        _from,
        {events, processes, options}
      ) do
    {event_pid, events} = events |> Map.pop(meta.pid)
    {ref, processes} = processes |> Map.pop(meta.pid)
    Process.demonitor(ref)
    Event.finalize(event_pid)
    Event.send(event_pid, options)
    Event.cleanup(event_pid)

    {:reply, :ok, {events, processes, options}}
  end

  @impl true
  def handle_call(
        {:ws_event, [:start], _measurements, meta},
        _from,
        {events, processes, options}
      ) do
    if events |> Map.has_key?(meta.socket.root_pid) do
      {:reply, :ok, {events, processes}}
    else
      the_request = get_the_request(meta)

      {:ok, pid} =
        Event.start_link(%{
          persona: options.persona,
          the_request: the_request
        })

      action = "#{inspect(meta.socket.view)}"
      Event.set_action(pid, action)
      events = events |> Map.put(meta.socket.root_pid, pid)
      ref = Process.monitor(meta.socket.root_pid)
      processes = processes |> Map.put(meta.socket.root_pid, ref)
      {:reply, :ok, {events, processes, options}}
    end
  end

  @impl true
  def handle_call(
        {:ws_event, [:stop], _measurements, meta},
        _from,
        {events, processes, options}
      ) do
    {event_pid, events} = events |> Map.pop(meta.socket.root_pid)
    {ref, processes} = processes |> Map.pop(meta.socket.root_pid)
    Process.demonitor(ref)
    Event.finalize(event_pid)
    Event.send(event_pid, options)
    Event.cleanup(event_pid)

    {:reply, :ok, {events, processes, options}}
  end

  def handle_call({:pid_to_event, socket_pid}, _from, {events, processes, options}) do
    {:reply, events |> Map.get(socket_pid), {events, processes, options}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, {e, stacktrace}}, {events, processes, options}) do
    # the request crashed
    {_, processes} = processes |> Map.pop(pid)
    {event_pid, events} = events |> Map.pop(pid)
    trace = Exception.format(:error, e, stacktrace)
    Event.add_error(event_pid, trace)
    Event.finalize(event_pid)
    Event.send(event_pid, options)
    Event.cleanup(event_pid)
    {:noreply, {events, processes, options}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, {events, processes, options}) do
    # the request finished, but weirdly
    {_, processes} = processes |> Map.pop(pid)
    {event_pid, events} = events |> Map.pop(pid)

    Event.finalize(event_pid)
    Event.send(event_pid, options)
    Event.cleanup(event_pid)
    {:noreply, {events, processes, options}}
  end

  defp get_the_request(%{uri: uri}) do
    [_, _, _, path] = uri |> String.split("/", parts: 4)
    "WS_GET /#{path}"
  end

  defp get_the_request(%{event: event, socket: %{view: view, router: router}} = meta) do
    route =
      Phoenix.Router.routes(router)
      |> Enum.find(fn
        %{plug_opts: ^view} -> true
        _ -> false
      end)

    case route do
      %{path: path} ->
        "WS_POST #{path} #{event}"

      _other ->
        case view do
          Phoenix.LiveDashboard.PageLive ->
            "WS_POST /dashboard/ #{event}"

          _ ->
            raise "cannot find path in route, meta: #{meta |> inspect()}"
        end
    end
  end

  def pid_to_event(src_pid) do
    pid_to_event(Process.whereis(@instance_name), src_pid)
  end

  def pid_to_event(nil, _), do: nil

  def pid_to_event(self_pid, src_pid) do
    ret = GenServer.call(self_pid, {:pid_to_event, src_pid})

    if ret != nil do
      ret
    else
      {:parent, parent_pid} = src_pid |> Process.info(:parent)

      if parent_pid == src_pid do
        nil
      else
        pid_to_event(self_pid, parent_pid)
      end
    end
  end

  defp make_http_event(conn, options) do
    the_request = "#{conn.method} #{conn.request_path}"

    the_request =
      if conn.query_string == "" do
        the_request
      else
        "#{the_request}?#{conn.query_string}"
      end

    {:ok, pid} =
      Event.start_link(%{
        persona: options.persona,
        the_request: the_request
      })

    Event.set_action(pid, "unknown")

    # TODO: this should probably be done smarter - perhaps via a callback or something, 
    # because honestly only the application owner can know what should really happen here
    case conn.request_path do
      "/assets/" <> _ ->
        Event.set_action(pid, "static")

      "/image/" <> _ ->
        Event.set_action(pid, "static")

      "/phoenix" <> _ ->
        Event.set_action(pid, "phoenix-internal")

      "/live/websocket" <> _ ->
        Event.set_action(pid, "phoenix-internal")

      _ ->
        :ok
    end

    pid
  end
end
