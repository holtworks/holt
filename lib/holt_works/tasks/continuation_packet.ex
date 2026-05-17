defmodule HoltWorks.Tasks.ContinuationPacket do
  @moduledoc """
  Durable machine-readable handoff for automatic agent continuations.
  """

  alias HoltWorks.Clock

  @schema_version "holtworks_continuation_packet/v1"
  @source "task_agent_continuation"
  @verification_tool "route_verification_review"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    task = normalize_map(value(attrs, "task"))
    work = normalize_map(value(attrs, "agent_work") || value(attrs, "work"))
    run = normalize_map(value(attrs, "agent_run") || value(attrs, "run"))
    resources = normalize_map(value(attrs, "resources"))
    context_packet = normalize_map(value(attrs, "context_packet"))
    depth = normalize_depth(value(attrs, "depth") || value(attrs, "continuation_depth"))

    %{
      "schema_version" => @schema_version,
      "packet_id" => optional_text(attrs, "packet_id", Clock.id("cont")),
      "source" => optional_text(attrs, "source", @source),
      "action" => "continue",
      "continuation_depth" => depth,
      "previous_task_id" => task_id(task, work, run),
      "previous_task_ref" => task_ref(task, work, run),
      "previous_agent_run_id" => run["id"] || work["agent_run_id"],
      "previous_runtime_run_id" => run["run_id"] || work["run_id"],
      "previous_agent_work_id" => work["id"] || run["work_id"],
      "agent_id" => optional_text(attrs, "agent_id") || work["agent_id"] || run["agent_id"],
      "agent_ref" => optional_text(attrs, "agent_ref") || work["agent_ref"],
      "resources" => resources,
      "context_packet_id" => context_packet["packet_id"],
      "context_budget" => context_packet["context_budget"],
      "memory_state" => context_packet["memory_state"],
      "verification_gate" =>
        normalize_map(value(attrs, "verification_gate")) |> default_verification_gate(),
      "required_loop" => required_loop(resources, context_packet),
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  def build(_attrs), do: build(%{})

  def prompt_section(packet) when is_map(packet) do
    """
    ## Continuation Packet
    Packet: #{packet["packet_id"]}
    Source: #{packet["source"]}
    Previous task: #{packet["previous_task_ref"] || packet["previous_task_id"] || "unknown"}
    Previous run: #{packet["previous_runtime_run_id"] || packet["previous_agent_run_id"] || "unknown"}
    Continuation depth: #{packet["continuation_depth"] || 1}
    Context packet: #{packet["context_packet_id"] || "none"}

    Required loop:
    #{loop_rows(packet["required_loop"] || %{})}
    """
    |> String.trim()
  end

  def prompt_section(_packet), do: nil

  defp default_verification_gate(gate) when map_size(gate) > 0, do: gate

  defp default_verification_gate(_gate) do
    %{
      "schema_version" => "holtworks_verification_gateway/v1",
      "status" => "required",
      "tool" => @verification_tool,
      "required" => true,
      "satisfied" => false
    }
  end

  defp required_loop(resources, context_packet) do
    %{
      "load_task_memory_context" => true,
      "read_parent_task" => true,
      "dereference_artifacts" => artifact_refs(context_packet) != [],
      "run_smallest_verifiable_step" => true,
      "save_handoff_or_node_heartbeat" => true,
      "submit_verification_review" => true,
      "workspace_required" => workspace_required?(resources)
    }
  end

  defp artifact_refs(context_packet) do
    context_packet
    |> value("artifact_refs")
    |> normalize_string_list()
  end

  defp workspace_required?(resources) do
    case value(resources, "workspace_required") do
      false -> false
      "false" -> false
      0 -> false
      _value -> true
    end
  end

  defp loop_rows(loop) do
    loop
    |> Enum.map(fn {key, value} -> "- #{key}: #{value}" end)
    |> case do
      [] -> "- none"
      rows -> Enum.join(rows, "\n")
    end
  end

  defp task_id(task, work, run) do
    task["id"] || task["_id"] || work["task_id"] || run["task_id"]
  end

  defp task_ref(task, work, run) do
    task["ref"] || task["task_ref"] || work["task_ref"] || run["task_ref"] || task["title"]
  end

  defp normalize_depth(value) when is_integer(value) and value > 0, do: value

  defp normalize_depth(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _other -> 1
    end
  end

  defp normalize_depth(_value), do: 1

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: [], else: [value]
  end

  defp normalize_string_list(_value), do: []

  defp optional_text(attrs, key, default \\ nil)

  defp optional_text(attrs, key, default) when is_map(attrs) do
    case Map.get(attrs, key, default) do
      nil ->
        default

      value ->
        text = value |> to_string() |> String.trim()
        if text == "", do: default, else: text
    end
  end

  defp optional_text(_attrs, _key, default), do: default

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp string_keys(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: string_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
