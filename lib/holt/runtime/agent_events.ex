defmodule Holt.Runtime.AgentEvents do
  @moduledoc """
  File-backed immutable event log for Holt agent sessions.

  Runtime run events remain the low-level execution ledger. Agent events are a
  higher-level projection for session timelines, model turns, and action spans.
  """

  alias Holt.{Clock, Paths}
  alias Holt.Runtime.AgentEventStore

  @schema_version "holt_agent_event/v1"
  @max_session_limit 1_000
  @valid_event_types ~w(
    session_start session_end
    user_message stream_chunk awaiting_user user_response
    llm_request llm_response
    action_invocation action_result
    agent_invocation_contract agent_runtime_event verification_evidence
    error model_fallback
  )

  def valid_event_types, do: @valid_event_types

  def append(session_id, event_type, payload \\ %{}, opts \\ [])

  def append(session_id, event_type, payload, opts)
      when is_binary(session_id) and is_binary(event_type) and is_map(payload) do
    root = Paths.workspace_root(opts)

    event =
      %{
        "schema_version" => @schema_version,
        "id" => Clock.id("agent_event"),
        "session_id" => session_id,
        "run_id" => opts[:run_id],
        "run_dir" => opts[:run_dir],
        "agent_id" => opts[:agent_id],
        "event_type" => event_type,
        "payload" => payload,
        "sequence" => event_sequence(session_id, opts),
        "trace_id" => event_trace_id(session_id, opts),
        "span_id" => opts[:span_id],
        "parent_span_id" => opts[:parent_span_id],
        "turn_id" => opts[:turn_id],
        "action_call_id" => opts[:action_call_id],
        "status" => opts[:status],
        "started_at" => opts[:started_at],
        "ended_at" => opts[:ended_at],
        "timestamp" => event_timestamp(opts),
        "metadata" => event_metadata(opts)
      }
      |> reject_empty()

    AgentEventStore.append(root, session_id, event)
    {:ok, event}
  end

  def append(_session_id, _event_type, _payload, _opts), do: {:error, :invalid_agent_event}

  def list_by_session(session_id, opts \\ [])

  def list_by_session(session_id, opts) when is_binary(session_id) do
    limit = clamp_limit(opts[:limit], @max_session_limit, @max_session_limit)

    events =
      opts
      |> Paths.workspace_root()
      |> AgentEventStore.list(session_id)
      |> maybe_filter_event_type(opts[:event_type])
      |> Enum.sort_by(&sequence_sort_key/1)
      |> Enum.take(limit)

    {:ok, events}
  end

  def list_by_session(_session_id, _opts), do: {:error, :invalid_session_id}

  def get_session_summary(session_id, opts \\ []) do
    with {:ok, events} <-
           list_by_session(session_id, Keyword.put(opts, :limit, @max_session_limit)),
         false <- events == [] do
      event_counts =
        events
        |> Enum.frequencies_by(& &1["event_type"])
        |> Enum.reject(fn {type, _count} -> type in [nil, ""] end)
        |> Map.new()

      actions =
        events
        |> Enum.filter(&(&1["event_type"] in ["action_invocation", "action_result"]))
        |> Enum.map(&get_in(&1, ["payload", "action"]))
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok,
       %{
         "session_id" => session_id,
         "total_events" => length(events),
         "event_counts" => event_counts,
         "actions" => actions,
         "started_at" => first_timestamp(events),
         "ended_at" => last_timestamp(events),
         "status" => session_status(events)
       }}
    else
      true -> {:error, :not_found}
      error -> error
    end
  end

  def get_session_tree(session_id, opts \\ []) do
    with {:ok, events} <-
           list_by_session(session_id, Keyword.put(opts, :limit, @max_session_limit)),
         false <- events == [] do
      root_span_id = session_span_id(session_id)
      trace_id = session_trace_id(events, session_id)
      root_events = Enum.filter(events, &(&1["span_id"] in [nil, root_span_id]))
      grouped_span_nodes = build_grouped_span_nodes(events, root_span_id)
      turn_nodes = build_turn_nodes(grouped_span_nodes)
      unparented_nodes = Enum.filter(grouped_span_nodes, &(node_parent_id(&1) == root_span_id))

      root =
        %{
          "id" => root_span_id,
          "span_id" => root_span_id,
          "parent_span_id" => nil,
          "type" => "session",
          "name" => "Agent session",
          "status" => session_status(events),
          "trace_id" => trace_id,
          "started_at" => first_timestamp(events),
          "ended_at" => last_timestamp(events),
          "duration_ms" => duration_ms(first_timestamp(events), last_timestamp(events)),
          "sequence_start" => first_sequence(events),
          "sequence_end" => last_sequence(events),
          "events" => event_refs(root_events),
          "children" => attach_turn_children(turn_nodes, grouped_span_nodes) ++ unparented_nodes
        }
        |> reject_empty()

      {:ok,
       %{
         "session_id" => session_id,
         "trace_id" => trace_id,
         "events_count" => length(events),
         "root" => root
       }}
    else
      true -> {:error, :not_found}
      error -> error
    end
  end

  def next_sequence(session_id, opts \\ [])

  def next_sequence(session_id, opts) when is_binary(session_id) do
    opts
    |> Paths.workspace_root()
    |> AgentEventStore.list(session_id)
    |> Enum.map(& &1["sequence"])
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> 0
      sequences -> Enum.max(sequences) + 1
    end
  end

  def next_sequence(_session_id, _opts), do: 0

  def session_span_id(session_id), do: "session:#{session_id}"
  def turn_span_id(turn), do: "turn:#{turn_id(turn)}"
  def llm_span_id(turn), do: "#{turn_span_id(turn)}:llm"
  def message_span_id(turn), do: "#{turn_span_id(turn)}:user_message"
  def action_span_id(nil), do: Clock.id("action_span")
  def action_span_id(action_call_id), do: "action:#{action_call_id}"
  def default_trace_id(session_id), do: "trace:#{session_id}"

  defp event_sequence(session_id, opts) do
    case opts[:sequence] do
      value when value in [nil, ""] -> next_sequence(session_id, opts)
      value -> value
    end
  end

  defp event_trace_id(session_id, opts) do
    case opts[:trace_id] do
      value when value in [nil, ""] -> default_trace_id(session_id)
      value -> value
    end
  end

  defp event_timestamp(opts) do
    case opts[:timestamp] do
      value when value in [nil, ""] -> Clock.iso_now()
      value -> value
    end
  end

  defp event_metadata(opts) do
    case opts[:metadata] do
      value when is_map(value) -> value
      _missing -> %{}
    end
  end

  defp session_trace_id(events, session_id) do
    case Enum.find_value(events, & &1["trace_id"]) do
      value when value in [nil, ""] -> default_trace_id(session_id)
      value -> value
    end
  end

  defp turn_id(turn) when is_integer(turn), do: turn
  defp turn_id(_turn), do: 0

  defp build_grouped_span_nodes(events, root_span_id) do
    events
    |> Enum.reject(&(&1["span_id"] in [nil, root_span_id]))
    |> Enum.group_by(& &1["span_id"])
    |> Enum.map(fn {span_id, span_events} ->
      build_span_node(span_id, span_events, root_span_id)
    end)
    |> Enum.sort_by(&span_sort_key/1)
  end

  defp span_sort_key(node), do: {sequence_start(node), node["id"]}

  defp sequence_start(node) do
    case node["sequence_start"] do
      value when is_integer(value) -> value
      _missing -> 0
    end
  end

  defp build_span_node(span_id, events, root_span_id) do
    sorted = Enum.sort_by(events, &sequence_sort_key/1)
    first = first_event(sorted)
    type = span_type(sorted)

    %{
      "id" => span_id,
      "span_id" => span_id,
      "parent_span_id" => parent_span_id(first, root_span_id),
      "type" => type,
      "name" => span_name(type, sorted),
      "status" => span_status(sorted),
      "trace_id" => first["trace_id"],
      "turn_id" => first["turn_id"],
      "action_call_id" => first["action_call_id"],
      "started_at" => first_timestamp(sorted),
      "ended_at" => last_timestamp(sorted),
      "duration_ms" => duration_ms(first_timestamp(sorted), last_timestamp(sorted)),
      "sequence_start" => first_sequence(sorted),
      "sequence_end" => last_sequence(sorted),
      "events" => event_refs(sorted),
      "children" => []
    }
    |> reject_empty()
  end

  defp build_turn_nodes(span_nodes) do
    span_nodes
    |> Enum.map(& &1["turn_id"])
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn turn ->
      %{
        "id" => turn_span_id(turn),
        "span_id" => turn_span_id(turn),
        "parent_span_id" => nil,
        "type" => "turn",
        "name" => "Turn #{turn}",
        "status" => "completed",
        "turn_id" => turn,
        "children" => []
      }
    end)
  end

  defp attach_turn_children(turn_nodes, span_nodes) do
    span_nodes_by_parent = Enum.group_by(span_nodes, &node_parent_id/1)

    Enum.map(turn_nodes, fn turn ->
      Map.put(turn, "children", Map.get(span_nodes_by_parent, turn["id"], []))
    end)
  end

  defp node_parent_id(node), do: node["parent_span_id"]

  defp parent_span_id(event, root_span_id) do
    case event["parent_span_id"] do
      value when value in [nil, ""] -> parent_for_turn(event, root_span_id)
      value -> value
    end
  end

  defp parent_for_turn(%{"turn_id" => turn_id}, _root_span_id) when is_integer(turn_id) do
    turn_span_id(turn_id)
  end

  defp parent_for_turn(_event, root_span_id), do: root_span_id

  defp span_type(events) do
    types = Enum.map(events, & &1["event_type"])

    cond do
      Enum.any?(types, &(&1 in ["action_invocation", "action_result"])) -> "action"
      Enum.any?(types, &(&1 in ["llm_request", "llm_response"])) -> "llm"
      Enum.any?(types, &(&1 == "user_message")) -> "message"
      true -> "event"
    end
  end

  defp span_name("action", events) do
    events
    |> Enum.find_value(&get_in(&1, ["payload", "action"]))
    |> case do
      nil -> "Action"
      action_name -> action_display_name(action_name)
    end
  end

  defp span_name("llm", events) do
    model = Enum.find_value(events, &get_in(&1, ["payload", "model"]))

    if model in [nil, ""], do: "LLM", else: "LLM #{model}"
  end

  defp span_name("message", _events), do: "User message"
  defp span_name(_type, events), do: first_event_type(events)

  defp first_event([]), do: %{}
  defp first_event([event | _events]), do: event

  defp first_event_type(events) do
    events
    |> first_event()
    |> Map.get("event_type", "Event")
  end

  defp span_status(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(& &1["status"])
    |> case do
      nil -> "completed"
      status -> status
    end
  end

  defp event_refs(events) do
    events
    |> Enum.sort_by(&sequence_sort_key/1)
    |> Enum.map(fn event ->
      %{
        "id" => event["id"],
        "event_type" => event["event_type"],
        "sequence" => event["sequence"],
        "status" => event["status"],
        "timestamp" => event["timestamp"],
        "payload" => event["payload"]
      }
      |> reject_empty()
    end)
  end

  defp session_status(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"event_type" => "session_end", "status" => status} -> status
      %{"event_type" => "error"} -> "error"
      _event -> nil
    end)
    |> case do
      nil -> "running"
      status -> status
    end
  end

  defp maybe_filter_event_type(events, nil), do: events

  defp maybe_filter_event_type(events, event_type),
    do: Enum.filter(events, &(&1["event_type"] == event_type))

  defp sequence_sort_key(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp sequence_sort_key(_event), do: 0

  defp first_sequence(events),
    do:
      events
      |> Enum.map(& &1["sequence"])
      |> Enum.filter(&is_integer/1)
      |> Enum.min(fn -> nil end)

  defp last_sequence(events),
    do:
      events
      |> Enum.map(& &1["sequence"])
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> nil end)

  defp first_timestamp([]), do: nil

  defp first_timestamp(events),
    do: events |> Enum.sort_by(&sequence_sort_key/1) |> List.first() |> Map.get("timestamp")

  defp last_timestamp([]), do: nil

  defp last_timestamp(events),
    do: events |> Enum.sort_by(&sequence_sort_key/1) |> List.last() |> Map.get("timestamp")

  defp duration_ms(nil, _ended_at), do: nil
  defp duration_ms(_started_at, nil), do: nil

  defp duration_ms(started_at, ended_at) do
    with {:ok, start_dt, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, end_dt, _offset} <- DateTime.from_iso8601(ended_at) do
      max(DateTime.diff(end_dt, start_dt, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp clamp_limit(nil, default, _max), do: default
  defp clamp_limit(limit, _default, max) when is_integer(limit), do: limit |> max(1) |> min(max)

  defp clamp_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {integer, ""} -> clamp_limit(integer, default, max)
      _ -> default
    end
  end

  defp clamp_limit(_limit, default, _max), do: default

  defp action_display_name(action_name) do
    action_name
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
