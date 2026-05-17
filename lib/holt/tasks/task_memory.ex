defmodule Holt.Tasks.TaskMemory do
  @moduledoc """
  File-backed compiled memory for long-running task agents.

  Raw artifacts are stored separately from compact context packets. Context
  packets carry small previews and artifact refs so continuations can stay
  within model budget while preserving exact evidence.
  """

  alias Holt.{Clock, JSON, Paths}
  alias Holt.Tasks.ContextBudgetGovernor

  @artifact_schema_version "holtworks_task_memory_artifact/v1"
  @chunk_schema_version "holtworks_task_memory_artifact_chunk/v1"
  @packet_schema_version "holtworks_task_memory_context_packet/v1"
  @chunk_chars 32_000
  @preview_chars 1_200

  def ensure_store(root) do
    Paths.ensure_workspace(root)
    File.mkdir_p!(Paths.tasks_dir(root))
    unless File.exists?(artifacts_path(root)), do: JSON.write(artifacts_path(root), [])
    unless File.exists?(chunks_path(root)), do: JSON.write(chunks_path(root), [])

    unless File.exists?(context_packets_path(root)),
      do: JSON.write(context_packets_path(root), [])

    :ok
  end

  def artifacts_path(root), do: Path.join(Paths.tasks_dir(root), "task_memory_artifacts.json")
  def chunks_path(root), do: Path.join(Paths.tasks_dir(root), "task_memory_artifact_chunks.json")

  def context_packets_path(root) do
    Path.join(Paths.tasks_dir(root), "task_memory_context_packets.json")
  end

  def record_artifact(root, task, attrs \\ %{})

  def record_artifact(root, task, attrs) when is_map(task) and is_map(attrs) do
    ensure_store(root)
    attrs = string_keys(attrs)
    content = content_text(attrs)
    artifact_ref = optional_text(attrs, "artifact_ref", Clock.id("task_memory_artifact"))
    chunks = chunk_content(artifact_ref, content)
    now = Clock.iso_now()

    artifact =
      %{
        "schema_version" => @artifact_schema_version,
        "artifact_ref" => artifact_ref,
        "task_id" => task["id"] || attrs["task_id"],
        "task_ref" => task["ref"] || attrs["task_ref"],
        "kind" => optional_text(attrs, "kind", "artifact"),
        "title" => optional_text(attrs, "title", default_title(attrs)),
        "source" => optional_text(attrs, "source", "task_memory"),
        "agent_run_id" => optional_text(attrs, "agent_run_id"),
        "agent_work_id" => optional_text(attrs, "agent_work_id"),
        "tool_name" => optional_text(attrs, "tool_name"),
        "content_preview" => String.slice(content, 0, @preview_chars),
        "content_bytes" => byte_size(content),
        "chunk_count" => length(chunks),
        "metadata" => normalize_map(value(attrs, "metadata")),
        "created_at" => now,
        "updated_at" => now
      }
      |> reject_empty()

    artifacts =
      root
      |> load_artifacts()
      |> Enum.reject(&(&1["artifact_ref"] == artifact_ref))
      |> Kernel.++([artifact])

    stored_chunks =
      root
      |> load_chunks()
      |> Enum.reject(&(&1["artifact_ref"] == artifact_ref))
      |> Kernel.++(chunks)

    JSON.write(artifacts_path(root), artifacts)
    JSON.write(chunks_path(root), stored_chunks)

    {:ok, artifact}
  end

  def record_artifact(_root, _task, _attrs), do: {:error, :invalid_artifact_attrs}

  def dereference_artifact(root, artifact_ref) when is_binary(artifact_ref) do
    ensure_store(root)

    case Enum.find(load_artifacts(root), &(&1["artifact_ref"] == artifact_ref)) do
      nil ->
        {:error, :artifact_not_found}

      artifact ->
        content =
          root
          |> load_chunks()
          |> Enum.filter(&(&1["artifact_ref"] == artifact_ref))
          |> Enum.sort_by(& &1["chunk_index"])
          |> Enum.map_join("", &(&1["content"] || ""))

        {:ok, Map.put(artifact, "content", content)}
    end
  end

  def dereference_artifact(_root, _artifact_ref), do: {:error, :invalid_ref}

  def context_packet(root, task, attrs \\ %{})

  def context_packet(root, task, attrs) when is_map(task) and is_map(attrs) do
    ensure_store(root)
    attrs = string_keys(attrs)
    specs = normalize_specs(value(attrs, "specs"))
    runs = normalize_list(value(attrs, "agent_runs"))
    artifacts = recent_artifacts(root, task["id"], limit: positive_int(value(attrs, "limit"), 12))
    evidence_ledgers = recent_json_records(root, "evidence_ledgers.json", task["id"], 8)
    approvals = recent_json_records(root, "human_approval_requests.json", task["id"], 8)
    comments = recent_comments(task, positive_int(value(attrs, "comment_limit"), 12))

    messages =
      value(attrs, "messages") ||
        synthetic_messages(task, specs, artifacts, evidence_ledgers, approvals, comments)

    context_budget =
      ContextBudgetGovernor.plan(%{
        "provider_profile" => normalize_map(value(attrs, "provider_profile")),
        "policy" => normalize_map(value(attrs, "policy")),
        "messages" => messages,
        "tools" => normalize_list(value(attrs, "tools")),
        "estimated_input_tokens" => value(attrs, "estimated_input_tokens"),
        "context_window" => value(attrs, "context_window"),
        "hard_limit_tokens" => value(attrs, "hard_limit_tokens"),
        "soft_limit_tokens" => value(attrs, "soft_limit_tokens"),
        "critical_limit_tokens" => value(attrs, "critical_limit_tokens"),
        "output_reserve_tokens" => value(attrs, "output_reserve_tokens"),
        "tool_reserve_tokens" => value(attrs, "tool_reserve_tokens")
      })

    packet =
      %{
        "schema_version" => @packet_schema_version,
        "packet_id" => optional_text(attrs, "packet_id", Clock.id("task_memory_packet")),
        "task_id" => task["id"],
        "task_ref" => task["ref"],
        "task_status" => task["status"],
        "task_title" => task["title"],
        "memory_state" =>
          memory_state(specs, artifacts, evidence_ledgers, approvals, context_budget, runs),
        "task_summary" => task_summary(task),
        "recent_comments" => comments,
        "runtime_specs" => Enum.map(specs, &spec_summary/1),
        "recent_artifacts" => Enum.map(artifacts, &artifact_summary/1),
        "recent_evidence_ledgers" => Enum.map(evidence_ledgers, &ledger_summary/1),
        "recent_approval_requests" => Enum.map(approvals, &approval_summary/1),
        "artifact_refs" => Enum.map(artifacts, & &1["artifact_ref"]),
        "context_budget" => context_budget,
        "prompt_section" => nil,
        "created_at" => Clock.iso_now()
      }
      |> reject_empty()

    packet = Map.put(packet, "prompt_section", context_prompt_section(packet))
    persist_context_packet(root, packet)
    {:ok, packet}
  end

  def context_packet(_root, _task, _attrs), do: {:error, :invalid_context_attrs}

  def context_prompt_section(packet) when is_map(packet) do
    """
    ## Task Memory Context
    Packet: #{packet["packet_id"]}
    Task: #{packet["task_ref"] || packet["task_id"] || "unknown"}
    Budget: #{get_in(packet, ["context_budget", "budget_state"]) || "unknown"} / #{get_in(packet, ["context_budget", "action"]) || "unknown"}

    Task summary:
    #{packet["task_summary"] || "none"}

    Runtime specs:
    #{summary_rows(packet["runtime_specs"] || [], "id", "title")}

    Recent artifacts:
    #{summary_rows(packet["recent_artifacts"] || [], "artifact_ref", "title")}

    Recent evidence ledgers:
    #{summary_rows(packet["recent_evidence_ledgers"] || [], "ledger_id", "source_tool_name")}
    """
    |> String.trim()
  end

  def context_prompt_section(_packet), do: nil

  def recent_artifacts(root, task_id, opts \\ []) do
    ensure_store(root)
    limit = Keyword.get(opts, :limit, 12)

    root
    |> load_artifacts()
    |> Enum.filter(&(&1["task_id"] == task_id))
    |> Enum.sort_by(&(&1["created_at"] || ""))
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  def context_packets(root, task_id, opts \\ []) do
    ensure_store(root)
    limit = Keyword.get(opts, :limit, 12)

    root
    |> load_context_packets()
    |> Enum.filter(&(&1["task_id"] == task_id))
    |> Enum.sort_by(&(&1["created_at"] || ""))
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp persist_context_packet(root, packet) do
    packets =
      root
      |> load_context_packets()
      |> Enum.reject(&(&1["packet_id"] == packet["packet_id"]))
      |> Kernel.++([packet])

    JSON.write(context_packets_path(root), packets)
    packet
  end

  defp load_artifacts(root), do: JSON.read(artifacts_path(root), [])
  defp load_chunks(root), do: JSON.read(chunks_path(root), [])
  defp load_context_packets(root), do: JSON.read(context_packets_path(root), [])

  defp recent_json_records(root, filename, task_id, limit) do
    path = Path.join(Paths.tasks_dir(root), filename)

    path
    |> JSON.read([])
    |> Enum.filter(&(&1["task_id"] == task_id))
    |> Enum.sort_by(&(&1["created_at"] || &1["inserted_at"] || ""))
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp chunk_content(artifact_ref, content) do
    content
    |> do_chunk([])
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %{
        "schema_version" => @chunk_schema_version,
        "artifact_ref" => artifact_ref,
        "chunk_index" => index,
        "content" => chunk
      }
    end)
  end

  defp do_chunk("", []), do: [""]
  defp do_chunk("", acc), do: Enum.reverse(acc)

  defp do_chunk(content, acc) do
    {chunk, rest} = String.split_at(content, @chunk_chars)
    do_chunk(rest, [chunk | acc])
  end

  defp content_text(attrs) do
    cond do
      is_binary(value(attrs, "content")) -> value(attrs, "content")
      is_binary(value(attrs, "body")) -> value(attrs, "body")
      true -> attrs |> value("content") |> inspect()
    end
  end

  defp default_title(attrs), do: optional_text(attrs, "kind", "Task memory artifact")

  defp synthetic_messages(task, specs, artifacts, ledgers, approvals, comments) do
    [
      %{
        "role" => "system",
        "content" =>
          "Task memory context for #{task["ref"] || task["id"]}: #{task["title"] || ""}"
      },
      %{
        "role" => "user",
        "content" =>
          Jason.encode!(%{
            "task" => task_summary(task),
            "specs" => Enum.map(specs, &spec_summary/1),
            "artifacts" => Enum.map(artifacts, &artifact_summary/1),
            "evidence_ledgers" => Enum.map(ledgers, &ledger_summary/1),
            "approval_requests" => Enum.map(approvals, &approval_summary/1),
            "comments" => comments
          })
      }
    ]
  end

  defp memory_state(specs, artifacts, ledgers, approvals, budget, runs) do
    %{
      "schema_version" => "holtworks_task_memory_state/v1",
      "runtime_spec_count" => length(specs),
      "artifact_count" => length(artifacts),
      "evidence_ledger_count" => length(ledgers),
      "approval_request_count" => length(approvals),
      "agent_run_count" => length(runs),
      "budget_state" => budget["budget_state"],
      "budget_action" => budget["action"],
      "durable_truth" => "file_backed_task_memory"
    }
  end

  defp task_summary(task) do
    """
    #{task["ref"] || task["id"]}: #{task["title"] || ""}
    Status: #{task["status"] || "unknown"}
    Priority: #{task["priority"] || "none"}
    Kind: #{task["kind"] || "task"}
    Description: #{String.slice(task["description"] || "", 0, @preview_chars)}
    """
    |> String.trim()
  end

  defp spec_summary(spec) do
    %{
      "id" => spec["id"],
      "kind" => spec["kind"],
      "title" => spec["title"],
      "content_preview" => String.slice(spec["content"] || "", 0, @preview_chars),
      "metadata" => spec["metadata"] || %{}
    }
    |> reject_empty()
  end

  defp artifact_summary(artifact) do
    artifact
    |> Map.take([
      "artifact_ref",
      "kind",
      "title",
      "source",
      "agent_run_id",
      "agent_work_id",
      "tool_name",
      "content_preview",
      "chunk_count",
      "created_at"
    ])
    |> reject_empty()
  end

  defp ledger_summary(ledger) do
    ledger
    |> Map.take(["ledger_id", "source_tool_name", "task_ref", "coverage", "created_at"])
    |> reject_empty()
  end

  defp approval_summary(approval) do
    approval
    |> Map.take([
      "approval_request_id",
      "status",
      "tool_name",
      "effect_scope",
      "risk_level",
      "created_at",
      "resolved_at"
    ])
    |> reject_empty()
  end

  defp recent_comments(task, limit) do
    task
    |> Map.get("comments", [])
    |> Enum.take(-limit)
    |> Enum.map(fn comment ->
      comment
      |> Map.take(["id", "body", "author", "created_at", "metadata"])
      |> update_in(["body"], &String.slice(to_string(&1), 0, @preview_chars))
      |> reject_empty()
    end)
  end

  defp summary_rows([], _id_key, _title_key), do: "- none"

  defp summary_rows(rows, id_key, title_key) do
    rows
    |> Enum.map(fn row ->
      "- #{row[id_key] || "unknown"}: #{row[title_key] || row["kind"] || "item"}"
    end)
    |> Enum.join("\n")
  end

  defp normalize_specs(specs) when is_list(specs) do
    specs
    |> Enum.filter(&is_map/1)
    |> Enum.map(&string_keys/1)
  end

  defp normalize_specs(_specs), do: []

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) do
    case Integer.parse(to_string(value)) do
      {number, ""} when number > 0 -> number
      _other -> default
    end
  end

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
