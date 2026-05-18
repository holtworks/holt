defmodule Holt.Tasks.Repository do
  @moduledoc """
  Core task CRUD, task specs, and task-local memory artifacts.
  """

  alias Holt.{Clock, Paths}
  alias Holt.Tasks.{Attributes, Store, TaskMemory}

  @statuses ~w(backlog todo in_progress waiting done canceled)
  @kinds ~w(task epic)
  @priorities ~w(urgent high medium low)
  @link_types ~w(blocks depends_on causes relates_to duplicates clones implements tests fixes tracks)

  @runtime_spec_kinds ~w(
    outcome_contract workflow_contract validation_contract verification_report walkthrough_video
    handoff decision_log mission_control mission_metric node_heartbeat behavior_profile
    preference_signal workflow_pattern memory_audit memory_export agent_trigger trigger_event
    research concept critique decision
  )

  @memory_kinds ~w(behavior_profile preference_signal workflow_pattern)
  @memory_scopes ~w(user team org)
  @portability_values ~w(exportable org_confidential private)

  @spec_kinds ~w(
    research concept critique decision outcome_contract workflow_contract
    validation_contract verification_report walkthrough_video handoff decision_log
    mission_control mission_metric node_heartbeat behavior_profile preference_signal
    workflow_pattern memory_audit memory_export agent_trigger trigger_event
    agent_stack_profile runtime_contract integration_contract cost_ledger failure_policy
  )

  def create(attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    Store.ensure(root)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, title} <- required_text(attrs, "title"),
         {:ok, kind} <- enum_value(attrs, "kind", @kinds, "task"),
         {:ok, status} <- enum_value(attrs, "status", @statuses, "todo"),
         {:ok, priority} <- enum_value(attrs, "priority", @priorities, "medium"),
         {:ok, estimate} <- estimate_value(Map.get(attrs, "estimate", nil)),
         {:ok, number} <- Store.next_number(root) do
      now = Clock.iso_now()

      task =
        %{
          "schema_version" => "holt_task/v1",
          "id" => Clock.id("task"),
          "number" => number,
          "ref" => Store.task_ref(number),
          "title" => title,
          "description" => optional_text(attrs, "description", ""),
          "kind" => kind,
          "status" => status,
          "priority" => priority,
          "estimate" => estimate,
          "due_date" => optional_text(attrs, "due_date"),
          "scheduled_start_at" => optional_text(attrs, "scheduled_start_at"),
          "recurrence" => normalize_recurrence(Map.get(attrs, "recurrence")),
          "labels" => normalize_labels(Map.get(attrs, "labels", [])),
          "links" => dependency_links(attrs) ++ normalize_links(Map.get(attrs, "links", [])),
          "origin" => optional_text(attrs, "origin", "local_cli"),
          "assignees" => normalize_assignees(Map.get(attrs, "assignees", [])),
          "agent_policy" => normalize_agent_policy(Map.get(attrs, "agent_policy", %{})),
          "parent_id" => optional_text(attrs, "parent_id"),
          "comments" => [],
          "attachments" => [],
          "agent_work" => [],
          "activity" => [
            activity("task.created", %{
              "status" => status,
              "priority" => priority,
              "kind" => kind
            })
          ],
          "created_at" => now,
          "updated_at" => now
        }
        |> reject_empty()

      root
      |> Store.load_tasks()
      |> Kernel.++([task])
      |> Store.store_tasks(root)

      {:ok, task}
    end
  end

  def list(opts \\ []) do
    root = Paths.workspace_root(opts)
    status = option(opts, :status)

    root
    |> Store.load_tasks()
    |> filter_status(status)
    |> Enum.sort_by(&Map.get(&1, "number", 0))
    |> Enum.map(&Store.enrich_task(root, &1))
  end

  def get(ref_or_id, opts \\ []) do
    root = Paths.workspace_root(opts)

    case Enum.find(Store.load_tasks(root), &Store.task_ref_matches?(&1, ref_or_id)) do
      nil -> {:error, :task_not_found}
      task -> {:ok, Store.enrich_task(root, task)}
    end
  end

  def update(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, patch} <- update_patch(attrs),
         {:ok, task} <-
           Store.update_task(root, ref_or_id, fn task ->
             fields = Map.keys(patch)

             task
             |> Map.merge(patch)
             |> touch()
             |> append_activity("task.updated", %{"fields" => fields})
           end) do
      {:ok, task}
    end
  end

  def add_comment(ref_or_id, body, opts \\ []) do
    root = Paths.workspace_root(opts)

    with {:ok, text} <- required_text(%{"body" => body}, "body"),
         {:ok, task} <-
           Store.update_task(root, ref_or_id, fn task ->
             comment = %{
               "id" => Clock.id("comment"),
               "body" => text,
               "author" => task_author(opts),
               "created_at" => Clock.iso_now()
             }

             task
             |> Map.update("comments", [comment], &(&1 ++ [comment]))
             |> touch()
             |> append_activity("task.comment_added", %{"comment_id" => comment["id"]})
           end) do
      {:ok, task}
    end
  end

  def delete_comment(ref_or_id, comment_id, opts \\ []) do
    root = Paths.workspace_root(opts)
    comment_id = to_string(comment_id)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, _comment} <- find_comment(task, comment_id) do
      Store.update_task(root, task["id"], fn current ->
        next_comments = Enum.reject(task_comments(current), &(&1["id"] == comment_id))

        current
        |> Map.put("comments", next_comments)
        |> touch()
        |> append_activity("task.comment_deleted", %{"comment_id" => comment_id})
      end)
    end
  end

  def add_label(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, name} <- required_text(attrs, "name") do
      color = optional_text(attrs, "color", "#2563eb")
      label = %{"name" => name, "color" => color}

      Store.update_task(root, ref_or_id, fn task ->
        labels = normalize_labels(task_labels(task))

        if label_exists?(labels, name) do
          task
        else
          task
          |> Map.put("labels", labels ++ [label])
          |> touch()
          |> append_activity("task.label_added", %{"name" => name, "color" => color})
        end
      end)
    end
  end

  def remove_label(ref_or_id, name, opts \\ []) do
    root = Paths.workspace_root(opts)
    normalized = Attributes.normalize_label_name(name)

    Store.update_task(root, ref_or_id, fn task ->
      labels = normalize_labels(task_labels(task))

      next_labels =
        Enum.reject(labels, &(Attributes.normalize_label_name(&1["name"]) == normalized))

      if length(next_labels) == length(labels) do
        task
      else
        task
        |> Map.put("labels", next_labels)
        |> touch()
        |> append_activity("task.label_removed", %{"name" => to_string(name)})
      end
    end)
  end

  def add_link(ref_or_id, target_ref_or_id, type, opts \\ []) do
    root = Paths.workspace_root(opts)

    with {:ok, link_type} <- enum_value(%{"type" => type}, "type", @link_types, "relates_to"),
         {:ok, source} <- get(ref_or_id, opts),
         {:ok, target} <- get(target_ref_or_id, opts),
         :ok <- ensure_not_self_link(source, target),
         :ok <- ensure_new_link(source, target) do
      link = %{
        "id" => Clock.id("link"),
        "target_id" => target["id"],
        "target_ref" => target["ref"],
        "type" => link_type
      }

      Store.update_task(root, source["id"], fn task ->
        task
        |> Map.update("links", [link], &(&1 ++ [link]))
        |> touch()
        |> append_activity("task.link_added", %{
          "link_id" => link["id"],
          "target_id" => target["id"],
          "target_ref" => target["ref"],
          "type" => link_type
        })
      end)
    end
  end

  def remove_link(ref_or_id, link_id, opts \\ []) do
    root = Paths.workspace_root(opts)
    link_id = to_string(link_id)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, link} <- find_link(task, link_id) do
      Store.update_task(root, task["id"], fn current ->
        next_links = Enum.reject(task_links(current), &(&1["id"] == link_id))

        current
        |> Map.put("links", next_links)
        |> touch()
        |> append_activity("task.link_removed", %{
          "link_id" => link_id,
          "target_id" => link["target_id"],
          "target_ref" => link["target_ref"],
          "type" => link["type"]
        })
      end)
    end
  end

  def set_estimate(ref_or_id, estimate, opts \\ []) do
    with {:ok, value} <- estimate_value(estimate) do
      update(ref_or_id, %{"estimate" => value}, opts)
    end
  end

  def set_priority(ref_or_id, priority, opts \\ []) do
    update(ref_or_id, %{"priority" => priority}, opts)
  end

  def save_spec(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    Store.ensure(root)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, kind} <- enum_value(attrs, "kind", @spec_kinds, nil),
         {:ok, content} <- required_text(attrs, "content") do
      spec_id = Clock.id("spec")
      title = optional_text(attrs, "title", default_spec_title(kind, task))
      relative_path = Path.join([".holtworks", "tasks", "specs", task["id"], spec_id <> ".md"])
      absolute_path = Path.join(root, relative_path)
      now = Clock.iso_now()

      spec =
        %{
          "schema_version" => "holt_task_spec/v1",
          "id" => spec_id,
          "task_id" => task["id"],
          "task_ref" => task["ref"],
          "kind" => kind,
          "title" => title,
          "path" => relative_path,
          "created_at" => now,
          "created_by" => task_author(opts),
          "metadata" => normalize_metadata(Map.get(attrs, "metadata", %{}))
        }

      File.mkdir_p!(Path.dirname(absolute_path))
      File.write!(absolute_path, content)

      root
      |> Store.load_specs()
      |> Kernel.++([spec])
      |> Store.store_specs(root)

      attachment = %{
        "id" => spec_id,
        "kind" => "spec",
        "artifact_kind" => kind,
        "spec_kind" => kind,
        "title" => title,
        "path" => relative_path
      }

      {:ok, updated_task} =
        Store.update_task(root, task["id"], fn current ->
          current
          |> Map.update("attachments", [attachment], &(&1 ++ [attachment]))
          |> touch(now)
          |> append_activity("task.spec_saved", %{
            "spec_id" => spec_id,
            "spec_kind" => kind
          })
        end)

      {:ok, Map.put(spec, "task", updated_task)}
    end
  end

  def list_specs(ref_or_id, opts \\ []) do
    root = Paths.workspace_root(opts)

    with {:ok, task} <- get(ref_or_id, opts) do
      kind = option(opts, :kind, "all")
      include_content? = option(opts, :include_content) != false
      content_limit = option(opts, :content_limit, 12_000)

      specs =
        root
        |> Store.load_specs()
        |> Enum.filter(&(&1["task_id"] == task["id"]))
        |> filter_spec_kind(kind)
        |> Enum.map(&maybe_include_spec_content(&1, root, include_content?, content_limit))

      {:ok, specs}
    end
  end

  def get_spec(spec_id, opts \\ []) do
    root = Paths.workspace_root(opts)
    task_ref = option(opts, :task_ref)

    case Enum.find(Store.load_specs(root), &(&1["id"] == spec_id)) do
      nil ->
        {:error, :spec_not_found}

      spec ->
        with :ok <- ensure_spec_task_scope(spec, task_ref, opts) do
          {:ok,
           maybe_include_spec_content(spec, root, true, option(opts, :content_limit, 50_000))}
        end
    end
  end

  def save_teammate_memory(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, memory_attrs} <- teammate_memory_attrs(attrs) do
      save_spec(ref_or_id, memory_attrs, opts)
    end
  end

  def load_teammate_runtime(ref_or_id, opts \\ []) do
    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, specs} <-
           list_specs(
             ref_or_id,
             Keyword.merge(opts,
               kind: "all",
               include_content: true,
               content_limit: option(opts, :content_limit, 1_600)
             )
           ) do
      runtime_specs = Enum.filter(specs, &(&1["kind"] in @runtime_spec_kinds))
      {:ok, teammate_runtime_markdown(task, runtime_specs, opts)}
    end
  end

  def read_memory_artifact(artifact_ref, opts \\ []) do
    root = Paths.workspace_root(opts)

    case TaskMemory.dereference_artifact(root, artifact_ref) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, :artifact_not_found} -> get_spec(artifact_ref, opts)
      {:error, :invalid_ref} -> get_spec(artifact_ref, opts)
      {:error, _reason} = error -> error
    end
  end

  def record_task_memory_artifact(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, artifact} <- TaskMemory.record_artifact(root, task, attrs),
         {:ok, updated_task} <-
           Store.update_task(root, task["id"], fn current ->
             attachment = %{
               "id" => artifact["artifact_ref"],
               "kind" => "task_memory_artifact",
               "artifact_kind" => artifact["kind"],
               "title" => artifact["title"],
               "artifact_ref" => artifact["artifact_ref"]
             }

             current
             |> Map.update("attachments", [attachment], &(&1 ++ [attachment]))
             |> touch()
             |> append_activity("task.memory_artifact_recorded", %{
               "artifact_ref" => artifact["artifact_ref"],
               "artifact_kind" => artifact["kind"]
             })
           end) do
      {:ok, Map.put(artifact, "task", Store.enrich_task(root, updated_task))}
    end
  end

  defp filter_status(tasks, status) when status in [nil, "", "all"], do: tasks

  defp filter_status(tasks, status) do
    Enum.filter(tasks, &(&1["status"] == status))
  end

  defp update_patch(attrs) do
    with {:ok, patch} <- maybe_put_required_text(%{}, attrs, "title"),
         {:ok, patch} <- maybe_put_optional_text(patch, attrs, "description"),
         {:ok, patch} <- maybe_put_optional_text(patch, attrs, "due_date"),
         {:ok, patch} <- maybe_put_optional_text(patch, attrs, "scheduled_start_at"),
         {:ok, patch} <- maybe_put_optional_text(patch, attrs, "parent_id"),
         {:ok, patch} <- maybe_put_enum(patch, attrs, "status", @statuses),
         {:ok, patch} <- maybe_put_enum(patch, attrs, "kind", @kinds),
         {:ok, patch} <- maybe_put_enum(patch, attrs, "priority", @priorities),
         {:ok, patch} <- maybe_put_estimate(patch, attrs) do
      patch =
        patch
        |> maybe_put_labels(attrs)
        |> maybe_put_recurrence(attrs)
        |> maybe_put_assignees(attrs)
        |> maybe_put_agent_policy(attrs)

      {:ok, patch}
    end
  end

  defp maybe_put_required_text(patch, attrs, key) do
    if Map.has_key?(attrs, key) do
      case required_text(attrs, key) do
        {:ok, value} -> {:ok, Map.put(patch, key, value)}
        error -> error
      end
    else
      {:ok, patch}
    end
  end

  defp maybe_put_optional_text(patch, attrs, key) do
    if Map.has_key?(attrs, key) do
      {:ok, Map.put(patch, key, optional_text(attrs, key))}
    else
      {:ok, patch}
    end
  end

  defp maybe_put_enum(patch, attrs, key, allowed) do
    if Map.has_key?(attrs, key) do
      case enum_value(attrs, key, allowed, nil) do
        {:ok, value} -> {:ok, Map.put(patch, key, value)}
        error -> error
      end
    else
      {:ok, patch}
    end
  end

  defp maybe_put_estimate(patch, attrs) do
    if Map.has_key?(attrs, "estimate") do
      case estimate_value(Map.get(attrs, "estimate")) do
        {:ok, value} -> {:ok, Map.put(patch, "estimate", value)}
        error -> error
      end
    else
      {:ok, patch}
    end
  end

  defp maybe_put_labels(patch, attrs) do
    if Map.has_key?(attrs, "labels") do
      Map.put(patch, "labels", normalize_labels(Map.get(attrs, "labels")))
    else
      patch
    end
  end

  defp maybe_put_recurrence(patch, attrs) do
    if Map.has_key?(attrs, "recurrence") do
      Map.put(patch, "recurrence", normalize_recurrence(Map.get(attrs, "recurrence")))
    else
      patch
    end
  end

  defp maybe_put_assignees(patch, attrs) do
    if Map.has_key?(attrs, "assignees") do
      Map.put(patch, "assignees", normalize_assignees(Map.get(attrs, "assignees")))
    else
      patch
    end
  end

  defp maybe_put_agent_policy(patch, attrs) do
    if Map.has_key?(attrs, "agent_policy") do
      Map.put(patch, "agent_policy", normalize_agent_policy(Map.get(attrs, "agent_policy")))
    else
      patch
    end
  end

  defp task_author(opts) do
    case Keyword.get(opts, :author) do
      author when is_binary(author) and author != "" -> author
      _missing -> "user"
    end
  end

  defp task_comments(%{"comments" => comments}) when is_list(comments), do: comments
  defp task_comments(_task), do: []

  defp task_labels(%{"labels" => labels}) when is_list(labels), do: labels
  defp task_labels(_task), do: []

  defp task_links(%{"links" => links}) when is_list(links), do: links
  defp task_links(_task), do: []

  defp label_exists?(labels, name) do
    normalized = Attributes.normalize_label_name(name)
    Enum.any?(labels, &(Attributes.normalize_label_name(&1["name"]) == normalized))
  end

  defp ensure_not_self_link(%{"id" => id}, %{"id" => id}), do: {:error, :self_link}
  defp ensure_not_self_link(_source, _target), do: :ok

  defp ensure_new_link(source, target) do
    if Enum.any?(task_links(source), &(&1["target_id"] == target["id"])) do
      {:error, :duplicate_link}
    else
      :ok
    end
  end

  defp find_link(task, link_id) do
    case Enum.find(task_links(task), &(&1["id"] == link_id)) do
      nil -> {:error, :link_not_found}
      link -> {:ok, link}
    end
  end

  defp find_comment(task, comment_id) do
    case Enum.find(task_comments(task), &(&1["id"] == comment_id)) do
      nil -> {:error, :comment_not_found}
      comment -> {:ok, comment}
    end
  end

  defp filter_spec_kind(specs, kind) when kind in [nil, "", "all"], do: specs
  defp filter_spec_kind(specs, kind), do: Enum.filter(specs, &(&1["kind"] == kind))

  defp maybe_include_spec_content(spec, _root, false, _content_limit), do: spec

  defp maybe_include_spec_content(spec, root, true, content_limit) do
    limit = positive_integer(content_limit, 12_000)
    path = Path.join(root, spec["path"])
    content = File.read!(path) |> String.slice(0, limit)
    Map.put(spec, "content", content)
  end

  defp ensure_spec_task_scope(_spec, task_ref, _opts) when task_ref in [nil, ""], do: :ok

  defp ensure_spec_task_scope(spec, task_ref, opts) do
    with {:ok, task} <- get(task_ref, opts) do
      if spec["task_id"] == task["id"] do
        :ok
      else
        {:error, :spec_task_mismatch}
      end
    end
  end

  defp teammate_memory_attrs(attrs) do
    kind = optional_text(attrs, "kind", "preference_signal")
    title = optional_text(attrs, "title")
    observed_pattern = optional_text(attrs, "observed_pattern")
    summary = optional_text(attrs, "summary")
    content = optional_text(attrs, "content")
    memory_scope = optional_text(attrs, "memory_scope", "team")
    portability = optional_text(attrs, "portability", "org_confidential")
    source_comment_ids = normalize_string_list(Map.get(attrs, "source_comment_ids", []))
    source_spec_ids = normalize_string_list(Map.get(attrs, "source_spec_ids", []))
    source_event_ids = normalize_string_list(Map.get(attrs, "source_event_ids", []))

    cond do
      kind not in @memory_kinds ->
        {:error, {:invalid_value, "kind", kind, @memory_kinds}}

      title in [nil, ""] ->
        {:error, {:missing_required, "title"}}

      observed_pattern in [nil, ""] ->
        {:error, {:missing_required, "observed_pattern"}}

      memory_scope not in @memory_scopes ->
        {:error, {:invalid_value, "memory_scope", memory_scope, @memory_scopes}}

      portability not in @portability_values ->
        {:error, {:invalid_value, "portability", portability, @portability_values}}

      source_comment_ids == [] and source_spec_ids == [] and source_event_ids == [] ->
        {:error, {:missing_required, "provenance"}}

      true ->
        metadata =
          %{
            "source" => "save_teammate_memory",
            "observed_pattern" => observed_pattern,
            "summary" => summary,
            "memory_scope" => memory_scope,
            "portability" => portability,
            "retention" => optional_text(attrs, "retention"),
            "affects_autonomy" => Map.get(attrs, "affects_autonomy", false),
            "confidence" => Map.get(attrs, "confidence"),
            "source_comment_ids" => source_comment_ids,
            "source_spec_ids" => source_spec_ids,
            "source_event_ids" => source_event_ids
          }
          |> reject_empty()

        {:ok,
         %{
           "kind" => kind,
           "title" => title,
           "content" =>
             teammate_memory_content(title, observed_pattern, summary, content, metadata),
           "metadata" => metadata
         }}
    end
  end

  defp teammate_memory_content(title, observed_pattern, summary, content, metadata) do
    """
    # #{title}

    Observed pattern:
    #{text_block(observed_pattern)}

    Summary:
    #{text_block(summary)}

    Content:
    #{text_block(content)}

    Governance:
    - Memory scope: #{metadata["memory_scope"]}
    - Portability: #{metadata["portability"]}
    - Affects autonomy: #{metadata["affects_autonomy"]}
    """
  end

  defp text_block(value) when is_binary(value), do: value
  defp text_block(_value), do: ""

  defp task_field_text(task, key) do
    case Map.get(task, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> "none"
    end
  end

  defp teammate_runtime_markdown(task, specs, opts) do
    comment_limit = positive_integer(option(opts, :comment_limit), 12)

    comments =
      task
      |> Map.get("comments", [])
      |> Enum.take(-comment_limit)
      |> Enum.map(fn comment ->
        "- #{comment["created_at"]}: #{comment["body"]}"
      end)
      |> case do
        [] -> "- none"
        rows -> Enum.join(rows, "\n")
      end

    spec_rows =
      specs
      |> Enum.map(fn spec ->
        """
        ## #{spec["kind"]}: #{spec["title"]}

        Spec ID: #{spec["id"]}

        #{text_block(spec["content"])}
        """
      end)
      |> case do
        [] -> "No runtime artifacts saved."
        rows -> Enum.join(rows, "\n")
      end

    """
    # Agent teammate runtime

    Task #{task["ref"]}: #{task["title"]}
    Status: #{task["status"]}
    Priority: #{task_field_text(task, "priority")}
    Estimate: #{task_field_text(task, "estimate")}

    Description:
    #{text_block(task["description"])}

    Recent comments:
    #{comments}

    Runtime artifacts:
    #{spec_rows}
    """
  end

  defp default_spec_title(kind, task), do: task["ref"] <> " " <> kind

  defp touch(task, now \\ Clock.iso_now()), do: Map.put(task, "updated_at", now)

  defp append_activity(task, type, data) do
    event = activity(type, data)
    Map.update(task, "activity", [event], &(&1 ++ [event]))
  end

  defp activity(type, data) do
    data
    |> Map.put("type", type)
    |> Map.put_new("at", Clock.iso_now())
  end

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp option(_opts, _key), do: nil

  defp option(opts, key, default) do
    case option(opts, key) do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  defp required_text(attrs, key), do: Attributes.required_text(attrs, key)

  defp optional_text(attrs, key, default \\ nil),
    do: Attributes.optional_text(attrs, key, default)

  defp enum_value(attrs, key, allowed, default),
    do: Attributes.enum_value(attrs, key, allowed, default)

  defp estimate_value(value), do: Attributes.estimate_value(value)

  defp normalize_string_list(value), do: Attributes.normalize_string_list(value)

  defp normalize_labels(value), do: Attributes.normalize_labels(value)

  defp normalize_links(value), do: Attributes.normalize_links(value)

  defp dependency_links(attrs), do: Attributes.dependency_links(attrs)

  defp normalize_assignees(value), do: Attributes.normalize_assignees(value)

  defp normalize_recurrence(value), do: Attributes.normalize_recurrence(value)

  defp normalize_metadata(value), do: Attributes.normalize_metadata(value)

  defp normalize_agent_policy(value), do: Attributes.normalize_agent_policy(value)

  defp positive_integer(value, default), do: Attributes.positive_integer(value, default)

  defp canonical_attrs(attrs) do
    if Attributes.canonical_map?(attrs), do: {:ok, attrs}, else: {:error, :invalid_attrs}
  end

  defp reject_empty(map), do: Attributes.reject_empty(map)
end
