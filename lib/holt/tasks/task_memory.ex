defmodule Holt.Tasks.TaskMemory do
  @moduledoc """
  File-backed compiled memory for long-running task agents.

  Raw artifacts are stored separately from compact context packets. Context
  packets carry small previews and artifact refs so continuations can stay
  within model budget while preserving exact evidence.
  """

  alias Holt.{Clock, JSON, Paths}
  alias Holt.Tasks.ContextBudgetGovernor

  @artifact_schema_version "holt_task_memory_artifact/v1"
  @chunk_schema_version "holt_task_memory_artifact_chunk/v1"
  @packet_schema_version "holt_task_memory_context_packet/v1"
  @chunk_chars 32_000
  @preview_chars 1_200
  @obsolete_artifact_attrs %{"body" => "content", "action_name" => "action"}

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

    with {:ok, attrs} <- canonical_attrs(attrs),
         :ok <- reject_obsolete_attrs(attrs, @obsolete_artifact_attrs),
         {:ok, content} <- content_text(attrs) do
      artifact_ref = optional_text(attrs, "artifact_ref", Clock.id("task_memory_artifact"))
      chunks = chunk_content(artifact_ref, content)
      now = Clock.iso_now()

      artifact =
        %{
          "schema_version" => @artifact_schema_version,
          "artifact_ref" => artifact_ref,
          "task_id" => task["id"],
          "task_ref" => task["ref"],
          "kind" => optional_text(attrs, "kind", "artifact"),
          "title" => optional_text(attrs, "title", default_title(attrs)),
          "source" => optional_text(attrs, "source", "task_memory"),
          "agent_run_id" => optional_text(attrs, "agent_run_id"),
          "agent_work_id" => optional_text(attrs, "agent_work_id"),
          "action" => optional_text(attrs, "action"),
          "content_preview" => String.slice(content, 0, @preview_chars),
          "content_bytes" => byte_size(content),
          "chunk_count" => length(chunks),
          "metadata" => normalize_map(Map.get(attrs, "metadata")),
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
          |> Enum.map_join("", &text_value(&1["content"], ""))

        {:ok, Map.put(artifact, "content", content)}
    end
  end

  def dereference_artifact(_root, _artifact_ref), do: {:error, :invalid_ref}

  def context_packet(root, task, attrs \\ %{})

  def context_packet(root, task, attrs) when is_map(task) and is_map(attrs) do
    ensure_store(root)

    with {:ok, attrs} <- canonical_attrs(attrs) do
      specs = normalize_specs(Map.get(attrs, "specs"))
      runs = normalize_list(Map.get(attrs, "agent_runs"))

      artifacts =
        recent_artifacts(root, task["id"], limit: positive_int(Map.get(attrs, "limit"), 12))

      evidence_ledgers = recent_json_records(root, "evidence_ledgers.json", task["id"], 8)
      approvals = recent_json_records(root, "human_approval_requests.json", task["id"], 8)
      comments = recent_comments(task, positive_int(Map.get(attrs, "comment_limit"), 12))

      messages =
        case Map.get(attrs, "messages") do
          value when is_list(value) ->
            value

          _value ->
            synthetic_messages(task, specs, artifacts, evidence_ledgers, approvals, comments)
        end

      context_budget = ContextBudgetGovernor.plan(context_budget_attrs(attrs, messages))

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
  end

  def context_packet(_root, _task, _attrs), do: {:error, :invalid_context_attrs}

  def context_prompt_section(packet) when is_map(packet) do
    """
    ## Task Memory Context
    Packet: #{packet["packet_id"]}
    Task: #{text_value(packet["task_ref"], "unknown")}
    Budget: #{text_value(get_in(packet, ["context_budget", "budget_state"]), "unknown")} / #{text_value(get_in(packet, ["context_budget", "action"]), "unknown")}

    Task summary:
    #{text_value(packet["task_summary"], "none")}

    Runtime specs:
    #{summary_rows(list_value(packet["runtime_specs"]), "id", "title")}

    Recent artifacts:
    #{summary_rows(list_value(packet["recent_artifacts"]), "artifact_ref", "title")}

    Recent evidence ledgers:
    #{summary_rows(list_value(packet["recent_evidence_ledgers"]), "ledger_id", "source_action")}
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
    |> Enum.sort_by(&text_field(&1, "created_at"))
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
    |> Enum.sort_by(&text_field(&1, "created_at"))
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
    |> Enum.sort_by(&text_field(&1, "created_at"))
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
    case Map.get(attrs, "content") do
      content when is_binary(content) -> {:ok, content}
      _value -> {:error, :missing_artifact_content}
    end
  end

  defp default_title(attrs), do: optional_text(attrs, "kind", "Task memory artifact")

  defp synthetic_messages(task, specs, artifacts, ledgers, approvals, comments) do
    [
      %{
        "role" => "system",
        "content" =>
          "Task memory context for #{text_value(task["ref"], "unknown")}: #{text_value(task["title"], "")}"
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
      "schema_version" => "holt_task_memory_state/v1",
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
    #{text_value(task["ref"], "unknown")}: #{text_value(task["title"], "")}
    Status: #{text_value(task["status"], "unknown")}
    Priority: #{text_value(task["priority"], "none")}
    Kind: #{text_value(task["kind"], "task")}
    Description: #{String.slice(text_value(task["description"], ""), 0, @preview_chars)}
    """
    |> String.trim()
  end

  defp spec_summary(spec) do
    %{
      "id" => spec["id"],
      "kind" => spec["kind"],
      "title" => spec["title"],
      "content_preview" => String.slice(text_value(spec["content"], ""), 0, @preview_chars),
      "metadata" => map_value(spec["metadata"])
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
      "action_name",
      "content_preview",
      "chunk_count",
      "created_at"
    ])
    |> reject_empty()
  end

  defp ledger_summary(ledger) do
    ledger
    |> Map.take(["ledger_id", "source_action", "task_ref", "coverage", "created_at"])
    |> reject_empty()
  end

  defp approval_summary(approval) do
    approval
    |> Map.take([
      "approval_request_id",
      "status",
      "action_name",
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
      |> update_in(["body"], &String.slice(text_value(&1, ""), 0, @preview_chars))
      |> reject_empty()
    end)
  end

  defp summary_rows([], _id_key, _title_key), do: "- none"

  defp summary_rows(rows, id_key, title_key) do
    rows
    |> Enum.map(fn row ->
      "- #{text_value(row[id_key], "unknown")}: #{summary_title(row, title_key)}"
    end)
    |> Enum.join("\n")
  end

  defp normalize_specs(specs) when is_list(specs) do
    specs
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&canonical_value?/1)
  end

  defp normalize_specs(_specs), do: []

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp context_budget_attrs(attrs, messages) do
    %{"messages" => messages}
    |> put_present("provider_profile", normalize_map(Map.get(attrs, "provider_profile")))
    |> put_present("policy", normalize_map(Map.get(attrs, "policy")))
    |> put_present("actions", normalize_list(Map.get(attrs, "actions")))
    |> put_existing(attrs, "estimated_input_tokens")
    |> put_existing(attrs, "hard_limit_tokens")
    |> put_existing(attrs, "soft_limit_tokens")
    |> put_existing(attrs, "critical_limit_tokens")
    |> put_existing(attrs, "output_reserve_tokens")
    |> put_existing(attrs, "action_reserve_tokens")
  end

  defp put_present(map, _key, value) when value in [%{}, []], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_existing(target, source, key) do
    if Map.has_key?(source, key) do
      Map.put(target, key, Map.get(source, key))
    else
      target
    end
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp optional_text(attrs, key, default \\ nil)

  defp optional_text(attrs, key, default) when is_map(attrs) do
    case Map.get(attrs, key, default) do
      nil ->
        default

      value when is_binary(value) ->
        text = String.trim(value)
        if text == "", do: default, else: text

      _value ->
        default
    end
  end

  defp optional_text(_attrs, _key, default), do: default

  defp canonical_attrs(attrs) do
    if canonical_value?(attrs) do
      {:ok, attrs}
    else
      {:error, :invalid_task_memory_attrs}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp reject_obsolete_attrs(attrs, replacements) do
    Enum.reduce_while(replacements, :ok, fn {key, replacement}, :ok ->
      if Map.has_key?(attrs, key) do
        {:halt, {:error, {:obsolete_task_memory_attr, key, replacement}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

  defp text_value(value, _default) when is_binary(value) and value != "", do: value
  defp text_value(_value, default), do: default

  defp text_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp summary_title(row, title_key) do
    case text_value(row[title_key], "") do
      "" -> text_value(row["kind"], "item")
      title -> title
    end
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
