defmodule PhoenixEvents do
  @moduledoc """
  A GenServer that attaches to various :telemetry events and turns them into "event"
  spans. Ensures that events are always finalized and (optionally) sent.

  Configuration options:

  | `:persona` | `String` | *required* | The event reporting persona should probably be the name of your application |
  | `:log_http` | `boolean` | optional | Defaults to true. Should we track http requests |
  | `:http_prefix` | `list` | optional | Defaults to `[:phoenix, :endpoint]`. The telemetry prefix used by phoenix endpoint for http requests |
  | `:log_live_view` | `boolean` | optional | Defaults to false. Should we track Phoenix.LiveView websocket requests |
  | `:live_view_prefix` | `list` | optional | Defaults to `[:phoenix, :live_view]`. The telemetry prefix used by phoenix_live_view |
  | `log_queries` | `boolean` | optional | Defaults to false. Should SQL queries (made via Ecto) be added to events. Requires setting the `:queries_prefix` option |
  | `:queries_prefix` | `list` | optional | The telemetry prefix for Ecto - Should probably be something in the vein of `[:myapp, :repo]` |
  | `:log_oban | `boolean` | optional | Should we treat Oban Job invocations as events |
  | `:log_events` | `boolean` | optional | Defaults to true. Should we send the event to Logger.info as it is being send |
  | `:send_events` | `boolean` | optional | Defaults to false. Should we send events to an Eventcollector instance |
  | `:eventcollector_host` | `String` | optional | The hostname/ip of the eventcollector instance |
  | `:eventcollector_port` | `String` | optional | The port of the eventcollector instance |
  | `:static_paths` | list(String) | optional | Defaults to `["assets", "image"]`. Which http path prefixes should be treated as the static action |
  | `:setup_func` | function(event, {kind, meta}) | optional | A callback function that will be invoked at the start of the event, that allows you to add any additional data to the event data structure. The default funciton is a noop |


  """

  use GenServer

  alias PhoenixEvents.Event

  @instance_name :phoenix_events_instance

  defp default_setup(ev, _), do: ev

  @defaults %{
    log_http: true,
    http_prefix: [:phoenix, :endpoint],
    log_live_view: false,
    live_view_prefix: [:phoenix, :live_view],
    log_queries: false,
    log_oban: false,
    log_events: true,
    send_events: false,
    static_paths: ["assets", "image"]
  }

  @impl true
  def init(options) when is_map(options) do
    # can't have functions in a compile-time constant I guess, so I have to do this, which is a tad annoying
    def_options = Map.put(@defaults, :setup_func, &default_setup/2)
    options = Map.merge(def_options, options)

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
        "phoenix_events-http-event-start",
        options.http_prefix ++ [:start],
        &PhoenixEvents.http_event/4,
        {self()}
      )

      :telemetry.attach(
        "phoenix_events-http-event-end",
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
        "phoenix_events_queries",
        options.queries_prefix ++ [:query],
        &PhoenixEvents.handle_query/4,
        {self()}
      )
    end

    if options.log_oban do
      :telemetry.attach(
        "phoenix_events_oban_start",
        [:oban, :job, :start],
        &PhoenixEvents.oban_start/4,
        {self()}
      )

      :telemetry.attach(
        "phoenix_events_oban_stop",
        [:oban, :job, :stop],
        &PhoenixEvents.oban_stop/4,
        {self()}
      )

      :telemetry.attach(
        "phoenix_events_oban_exception",
        [:oban, :job, :exception],
        &PhoenixEvents.oban_exception/4,
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
    event_pid = pid_to_event(phoenix_events_pid, self())

    if event_pid != nil do
      Event.add_query(event_pid, {meta.query, div(measurements.total_time, 1_000_000)})
    end
  end

  def oban_start(_name, _m, meta, {pid}) do
    GenServer.call(pid, {:oban_start, meta, self()})
  end

  def oban_stop(_name, _m, _, {pid}) do
    GenServer.call(pid, {:oban_stop, self()})
  end

  def oban_exception(_name, _measure, meta, {pid}) do
    GenServer.call(pid, {:oban_exception, meta, self()})
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
    {:memory, bytes_end} = Process.info(meta.conn.owner, :memory)
    Event.finalize(event_pid, %{memory: bytes_end})
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
    {:memory, bytes_start} = Process.info(meta.pid, :memory)

    {:ok, pid} =
      Event.start_link(%{
        persona: options.persona,
        the_request: meta.the_request,
        memory: bytes_start
      })

    Event.set_action(pid, meta.action)
    Event.setup(pid, options.setup_func, [{:custom, meta}])

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
    {:memory, bytes_end} = Process.info(meta.pid, :memory)
    Event.finalize(event_pid, %{memory: bytes_end})
    Event.send(event_pid, options)
    Event.cleanup(event_pid)

    {:reply, :ok, {events, processes, options}}
  end

  @impl true
  def handle_call({:oban_start, meta, o_pid}, _from, {events, processes, options}) do
    {:memory, bytes_start} = Process.info(o_pid, :memory)

    {:ok, pid} =
      Event.start_link(%{
        persona: options.persona,
        the_request: "OBAN #{meta.job.queue}",
        memory: bytes_start
      })

    Event.set_action(pid, meta.job.worker)
    Event.setup(pid, options.setup_func, [{:oban, meta}])

    Event.add_volatile(pid, :oban, %{
      queue: meta.job.queue,
      args: meta.job.args,
      attempt: meta.job.attempt
    })

    events = events |> Map.put(o_pid, pid)
    ref = Process.monitor(o_pid)
    processes = processes |> Map.put(o_pid, ref)

    {:reply, :ok, {events, processes, options}}
  end

  @impl true
  def handle_call({:oban_stop, o_pid}, _from, {events, processes, options}) do
    {event_pid, events} = events |> Map.pop(o_pid)
    {ref, processes} = processes |> Map.pop(o_pid)
    Process.demonitor(ref)
    {:memory, bytes_end} = Process.info(o_pid, :memory)
    Event.finalize(event_pid, %{memory: bytes_end})
    Event.send(event_pid, options)
    Event.cleanup(event_pid)
    {:reply, :ok, {events, processes, options}}
  end

  @impl true
  def handle_call({:oban_exception, meta, o_pid}, _from, {events, processes, options}) do
    {event_pid, events} = events |> Map.pop(o_pid)
    {ref, processes} = processes |> Map.pop(o_pid)
    Process.demonitor(ref)

    case meta do
      %{kind: kind, reason: error, stacktrace: stack} ->
        trace = Exception.format(kind, error, stack)
        PhoenixEvents.Event.add_error(event_pid, trace)

      _ ->
        :ok
    end

    {:memory, bytes_end} = Process.info(o_pid, :memory)
    Event.finalize(event_pid, %{memory: bytes_end})
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
      {:reply, :ok, {events, processes, options}}
    else
      {:memory, bytes_start} = Process.info(meta.socket.root_pid, :memory)
      the_request = get_the_request(meta)

      {:ok, pid} =
        Event.start_link(%{
          persona: options.persona,
          the_request: the_request,
          memory: bytes_start
        })

      action = "#{inspect(meta.socket.view)}"
      Event.set_action(pid, action)

      Event.setup(pid, options.setup_func, [{:ws, meta.socket}])

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
    {:memory, bytes_end} = Process.info(meta.socket.root_pid, :memory)
    Event.finalize(event_pid, %{memory: bytes_end})
    Event.send(event_pid, options)
    Event.cleanup(event_pid)

    {:reply, :ok, {events, processes, options}}
  end

  @impl true
  def handle_call({:pid_to_event, socket_pid}, _from, {events, processes, options}) do
    {:reply, events |> Map.get(socket_pid), {events, processes, options}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, {e, stacktrace}}, {events, processes, options}) do
    # the request crashed
    {_, processes} = processes |> Map.pop(pid)
    {event_pid, events} = events |> Map.pop(pid)

    if event_pid != nil do
      trace = Exception.format(:error, e, stacktrace)
      Event.add_error(event_pid, trace)

      case Process.info(pid, :memory) do
        {:memory, bytes_end} ->
          Event.finalize(event_pid, %{memory: bytes_end})

        _ ->
          Event.finalize(event_pid)
      end

      Event.send(event_pid, options)
      Event.cleanup(event_pid)
    end

    {:noreply, {events, processes, options}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, {events, processes, options}) do
    # the request finished, but weirdly
    {_, processes} = processes |> Map.pop(pid)
    {event_pid, events} = events |> Map.pop(pid)

    if event_pid != nil do
      case Process.info(pid, :memory) do
        {:memory, bytes_end} ->
          Event.finalize(event_pid, %{memory: bytes_end})

        _ ->
          Event.finalize(event_pid)
      end

      Event.send(event_pid, options)
      Event.cleanup(event_pid)
    end

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

  @doc """
  Tries to find an event associated with the given process, returns nil if none are found
  It does walk up the process tree to see if any of the parents are associated with an event and 
  returns that event if that is the case
  """
  @spec pid_to_event(pid()) :: pid() | nil
  def pid_to_event(src_pid) do
    pid_to_event(Process.whereis(@instance_name), src_pid)
  end

  defp pid_to_event(nil, _), do: nil

  defp pid_to_event(self_pid, src_pid) do
    ret = GenServer.call(self_pid, {:pid_to_event, src_pid})

    if ret != nil do
      ret
    else
      case try_get_parent(src_pid) do
        nil ->
          nil

        parent_pid ->
          pid_to_event(self_pid, parent_pid)
      end
    end
  end

  if System.otp_release() |> String.to_integer() >= 25 do
    # OTP/25 supports a nice thing where we can just get the parent via process info
    defp try_get_parent(pid) do
      case Process.info(pid, :parent) do
        nil ->
          nil

        {:parent, :undefined} ->
          nil

        {:parent, ^pid} ->
          nil

        {:parent, parent_pid} ->
          parent_pid
      end
    end
  else
    #  we have to try to do this the hacky ugly dumb way
    defp try_get_parent(pid) do
      case Process.info(pid, :dictionary) do
        nil ->
          nil

        {:dictionary, dictionary} ->
          case Keyword.get(dictionary, :"$ancestors") do
            [parent | _] -> parent |> ensure_pid()
            _ -> nil
          end
      end
    end

    defp ensure_pid(maybe_pid) when is_pid(maybe_pid), do: maybe_pid

    defp ensure_pid(_), do: nil
  end

  defp make_http_event(conn, options) do
    {:memory, bytes_start} = Process.info(conn.owner, :memory)
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
        the_request: the_request,
        memory: bytes_start
      })

    Event.setup(pid, options.setup_func, [{:http, conn}])
    Event.set_action(pid, "unknown")

    # TODO: this should probably be done smarter - perhaps via a callback or something, 
    # because honestly only the application owner can know what should really happen here
    did_set_action =
      case conn.request_path do
        "/phoenix" <> _ ->
          Event.set_action(pid, "phoenix-internal")
          true

        "/live/websocket" <> _ ->
          Event.set_action(pid, "phoenix-internal")
          true

        _ ->
          false
      end

    unless did_set_action and is_list(options.static_paths) do
      is_static =
        options.static_paths
        |> Enum.any?(fn path ->
          conn.request_path |> String.starts_with?("/#{path}")
        end)

      if is_static do
        Event.set_action(pid, "static")
      end
    end

    pid
  end
end
