defmodule Holt.Tasks.ContinuationPacket do
  @moduledoc """
  Durable machine-readable handoff for automatic agent continuations.
  """

  alias Holt.Clock

  @schema_version "holt_continuation_packet/v1"
  @source "task_agent_continuation"
  @verification_action "route_verification_review"
  @unsupported_keys ~w(depth work run agent_id agent_ref task_id task_ref)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_packet(reason)
    end
  end

  def build(_attrs), do: rejected_packet("invalid_attrs")

  def prompt_section(packet) when is_map(packet) do
    """
    ## Continuation Packet
    Packet: #{packet_text(packet, "packet_id", "unknown")}
    Source: #{packet_text(packet, "source", @source)}
    Previous task: #{packet_text(packet, "previous_task_ref", "unknown")}
    Previous run: #{packet_text(packet, "previous_runtime_run_id", "unknown")}
    Continuation depth: #{packet_depth(packet)}
    Context packet: #{packet_text(packet, "context_packet_id", "none")}

    Required loop:
    #{loop_rows(loop_map(packet["required_loop"]))}
    """
    |> String.trim()
  end

  def prompt_section(_packet), do: nil

  defp input(attrs) do
    with :ok <- canonical_top_level_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, packet_id} <-
           optional_text(attrs, "packet_id", Clock.id("cont"), "invalid_packet_id"),
         {:ok, source} <- optional_text(attrs, "source", @source, "invalid_source"),
         {:ok, task} <- optional_map_field(attrs, "task", "invalid_task"),
         {:ok, work} <- optional_map_field(attrs, "agent_work", "invalid_agent_work"),
         {:ok, run} <- optional_map_field(attrs, "agent_run", "invalid_agent_run"),
         {:ok, resources} <- optional_map_field(attrs, "resources", "invalid_resources"),
         {:ok, context_packet} <-
           optional_map_field(attrs, "context_packet", "invalid_context_packet"),
         {:ok, gate} <-
           optional_map_field(attrs, "verification_gate", "invalid_verification_gate"),
         {:ok, depth} <- continuation_depth(attrs),
         :ok <- validate_task(task),
         :ok <- validate_agent_work(work),
         :ok <- validate_agent_run(run),
         :ok <- validate_resources(resources),
         :ok <- validate_context_packet(context_packet) do
      {:ok,
       %{
         packet_id: packet_id,
         source: source,
         task: task,
         work: work,
         run: run,
         resources: resources,
         context_packet: context_packet,
         verification_gate: gate,
         continuation_depth: depth
       }}
    end
  end

  defp build_canonical(input) do
    task = input.task
    work = input.work
    run = input.run
    resources = input.resources
    context_packet = input.context_packet

    %{
      "schema_version" => @schema_version,
      "packet_id" => input.packet_id,
      "source" => input.source,
      "action" => "continue",
      "continuation_depth" => input.continuation_depth,
      "previous_task_id" => text_field(task, "id"),
      "previous_task_ref" => text_field(task, "ref"),
      "previous_agent_run_id" => text_field(run, "id"),
      "previous_runtime_run_id" => text_field(work, "run_id"),
      "previous_agent_work_id" => text_field(work, "id"),
      "agent_id" => text_field(work, "agent_id"),
      "agent_ref" => text_field(work, "agent_ref"),
      "resources" => resources,
      "context_packet_id" => context_packet["packet_id"],
      "context_budget" => context_packet["context_budget"],
      "memory_state" => context_packet["memory_state"],
      "verification_gate" => default_verification_gate(input.verification_gate),
      "required_loop" => required_loop(resources, context_packet),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_packet(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp default_verification_gate(gate) when map_size(gate) > 0, do: gate

  defp default_verification_gate(_gate) do
    %{
      "schema_version" => "holt_verification_gateway/v1",
      "status" => "required",
      "action" => @verification_action,
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
    Map.get(context_packet, "artifact_refs", [])
  end

  defp workspace_required?(resources) do
    case Map.fetch(resources, "workspace_required") do
      {:ok, false} -> false
      _missing_or_true -> true
    end
  end

  defp loop_rows(loop) do
    case Enum.map(loop, fn {key, value} -> "- #{key}: #{value}" end) do
      [] -> "- none"
      rows -> Enum.join(rows, "\n")
    end
  end

  defp continuation_depth(attrs) do
    case Map.fetch(attrs, "continuation_depth") do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_continuation_depth"}
      :error -> {:ok, 1}
    end
  end

  defp packet_text(packet, key, default) do
    case text_field(packet, key) do
      nil -> default
      value -> value
    end
  end

  defp packet_depth(packet) do
    case Map.fetch(packet, "continuation_depth") do
      {:ok, depth} when is_integer(depth) and depth > 0 -> depth
      _value -> 1
    end
  end

  defp validate_task(task) do
    with :ok <- optional_text_field(task, "id", "invalid_task"),
         :ok <- optional_text_field(task, "ref", "invalid_task") do
      :ok
    end
  end

  defp validate_agent_work(work) do
    with :ok <- optional_text_field(work, "id", "invalid_agent_work"),
         :ok <- optional_text_field(work, "run_id", "invalid_agent_work"),
         :ok <- optional_text_field(work, "agent_id", "invalid_agent_work"),
         :ok <- optional_text_field(work, "agent_ref", "invalid_agent_work") do
      :ok
    end
  end

  defp validate_agent_run(run) do
    with :ok <- optional_text_field(run, "id", "invalid_agent_run"),
         :ok <- optional_text_field(run, "run_id", "invalid_agent_run") do
      :ok
    end
  end

  defp validate_resources(resources) do
    with :ok <- optional_boolean_field(resources, "workspace_required", "invalid_resources"),
         :ok <-
           optional_string_list_field(
             resources,
             "task_memory_artifact_refs",
             "invalid_resources"
           ) do
      :ok
    end
  end

  defp validate_context_packet(packet) do
    with :ok <- optional_text_field(packet, "packet_id", "invalid_context_packet"),
         :ok <- optional_map_field_present(packet, "context_budget", "invalid_context_packet"),
         :ok <- optional_map_field_present(packet, "memory_state", "invalid_context_packet"),
         :ok <- optional_string_list_field(packet, "artifact_refs", "invalid_context_packet") do
      :ok
    end
  end

  defp optional_map_field(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> canonical_map(value, reason)
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp optional_map_field_present(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp optional_text(attrs, key, default, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, default}
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          _text -> :ok
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp optional_boolean_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp optional_string_list_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> string_list(values, reason)
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp string_list(values, reason) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, reason}
    end
  end

  defp text_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _missing ->
        nil
    end
  end

  defp unsupported_arguments(attrs) do
    @unsupported_keys
    |> Enum.find(&Map.has_key?(attrs, &1))
    |> unsupported_argument_error()
  end

  defp unsupported_argument_error(nil), do: :ok
  defp unsupported_argument_error(key), do: {:error, "unsupported_argument:" <> key}

  defp canonical_top_level_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp canonical_map(map, reason) do
    if canonical_map?(map), do: {:ok, map}, else: {:error, reason}
  end

  defp canonical_map?(map) when is_map(map) do
    Enum.all?(map, fn
      {key, value} when is_binary(key) -> canonical_value?(value)
      {_key, _value} -> false
    end)
  end

  defp canonical_value?(value) when is_map(value), do: canonical_map?(value)
  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp loop_map(value) when is_map(value), do: value
  defp loop_map(_value), do: %{}

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
