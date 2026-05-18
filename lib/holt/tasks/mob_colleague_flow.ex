defmodule Holt.Tasks.MobColleagueFlow do
  @moduledoc """
  Durable mob-colleague orchestration for task agent work.

  A mob colleague is a specialist agent profile that leaves task comments for
  the current worker to use while coding, then receives a review task when the
  groundwork agent finishes.
  """

  alias Holt.{Agents, Clock}
  alias Holt.Tasks.{Attributes, Repository, Store}

  @schema_version "holt_mob_colleague_flow/v1"
  @schedule_schema_version "holt_mob_colleague_flow_schedule/v1"
  @trigger_schema_version "holt_mob_colleague_flow_trigger/v1"
  @comment_schema_version "holt_mob_colleague_comment/v1"
  @observation_work_source "mob_colleague_observation"
  @setup_task_origin "mob_colleague_setup"
  @review_work_source "mob_colleague_review"
  @allowed_comment_phases ~w(groundwork review)
  @top_level_obsolete_keys ~w(
    agent agent_id specialist_agent qa_agent reviewer_agent
    comment comments live_comment observation_title review_title setup_title
  )
  @colleague_agent_obsolete_keys ~w(
    id name title handle ref role work_role system_prompt skill capability
  )

  def schedule(root, ref_or_id, attrs, opts \\ [])

  def schedule(root, ref_or_id, attrs, opts) when is_binary(root) and is_map(attrs) do
    opts = Keyword.put(opts, :workspace, root)

    with {:ok, attrs} <- canonical_attrs(attrs),
         :ok <-
           reject_obsolete_keys(attrs, @top_level_obsolete_keys, "schedule_mob_colleague_flow"),
         {:ok, parent} <- Repository.get(ref_or_id, opts),
         {:ok, groundwork_agent_id} <- required_text(attrs, "groundwork_agent_id"),
         {:ok, colleague_attrs} <- required_map(attrs, "colleague_agent"),
         :ok <-
           reject_obsolete_keys(
             colleague_attrs,
             @colleague_agent_obsolete_keys,
             "colleague_agent"
           ),
         {:ok, colleague_agent} <- normalize_colleague_agent(colleague_attrs),
         {:ok, setup_task_attrs} <- required_task_template(attrs, "setup_task"),
         {:ok, observation_task_attrs} <- required_task_template(attrs, "observation_task"),
         {:ok, observation_message} <- required_text(attrs, "observation_message"),
         {:ok, review_task_attrs} <- required_task_template(attrs, "review_task"),
         {:ok, review_message} <- required_text(attrs, "review_message"),
         {:ok, comments} <- collaboration_comments(attrs),
         {:ok, profile} <- Agents.create(root, colleague_agent),
         {:ok, setup_task} <- create_setup_task(parent, profile, setup_task_attrs, opts),
         {:ok, observation_task} <-
           create_observation_task(parent, profile, observation_task_attrs, opts),
         {:ok, updated_parent, flow, written_comments} <-
           arm_flow(
             root,
             parent,
             groundwork_agent_id,
             profile,
             setup_task,
             observation_task,
             observation_task_attrs,
             observation_message,
             review_task_attrs,
             review_message,
             normalize_string_list(Map.get(attrs, "documentation_sources")),
             comments
           ) do
      {:ok,
       %{
         "schema_version" => @schedule_schema_version,
         "flow" => flow,
         "task" => Store.enrich_task(root, updated_parent),
         "colleague_agent" => profile,
         "setup_task" => setup_task,
         "observation_task" => observation_task,
         "observation_start_request" => observation_start_request(flow, observation_task),
         "collaboration_comments" => written_comments
       }}
    end
  end

  def schedule(_root, _ref_or_id, _attrs, _opts), do: {:error, :invalid_mob_colleague_flow}

  def trigger_after_work(root, task, work, run, opts \\ [])

  def trigger_after_work(root, task, work, run, opts)
      when is_binary(root) and is_map(task) and is_map(work) do
    if triggering_work?(work) do
      task
      |> matching_armed_flows(work)
      |> Enum.reduce({:ok, task, [], []}, fn flow, {:ok, current_task, results, starts} ->
        case create_review_start(root, current_task, flow, work, run, opts) do
          {:ok, updated_task, result, start_request} ->
            {:ok, updated_task, results ++ [result], starts ++ [start_request]}

          {:error, reason} ->
            case mark_flow_failed(root, current_task, flow, reason) do
              {:ok, updated_task, result} ->
                {:ok, updated_task, results ++ [result], starts}

              {:error, _update_reason} ->
                {:ok, current_task, results ++ [failed_trigger_result(flow, reason)], starts}
            end
        end
      end)
      |> case do
        {:ok, updated_task, results, starts} ->
          {:ok, %{task: updated_task, flow_results: results, start_requests: starts}}
      end
    else
      {:ok, %{task: task, flow_results: [], start_requests: []}}
    end
  end

  def trigger_after_work(_root, task, _work, _run, _opts),
    do: {:ok, %{task: task, flow_results: [], start_requests: []}}

  def mark_observation_agent_work_started(root, task, flow_id, observation_result)
      when is_binary(root) and is_map(task) and is_binary(flow_id) do
    agent_work = result_work(observation_result)
    run = result_run(observation_result)

    Store.update_task(root, task["id"], fn current ->
      current
      |> update_flow(flow_id, fn flow ->
        flow
        |> Map.put("status", "observing")
        |> Map.put("observation_agent_work_id", agent_work["id"])
        |> Map.put("observation_run_id", run["id"])
        |> Map.put("observation_agent_work_status", agent_work["status"])
        |> Map.put("observation_runtime_status", run["status"])
        |> Map.put("observation_started_at", Clock.iso_now())
        |> reject_empty()
      end)
      |> touch()
      |> append_activity("task.mob_colleague_observation_started", %{
        "flow_id" => flow_id,
        "observation_agent_work_id" => agent_work["id"],
        "observation_run_id" => run["id"]
      })
    end)
  end

  def mark_observation_agent_work_started(_root, _task, _flow_id, _observation_result),
    do: {:error, :invalid_mob_colleague_flow}

  def mark_observation_agent_work_failed(root, task, flow_id, reason)
      when is_binary(root) and is_map(task) and is_binary(flow_id) do
    Store.update_task(root, task["id"], fn current ->
      current
      |> update_flow(flow_id, fn flow ->
        flow
        |> Map.put("status", "observation_start_failed")
        |> Map.put("observation_start_failure", inspect(reason))
        |> Map.put("observation_start_failed_at", Clock.iso_now())
        |> reject_empty()
      end)
      |> touch()
      |> append_activity("task.mob_colleague_observation_start_failed", %{
        "flow_id" => flow_id,
        "reason" => inspect(reason)
      })
    end)
  end

  def mark_observation_agent_work_failed(_root, _task, _flow_id, _reason),
    do: {:error, :invalid_mob_colleague_flow}

  def mark_review_agent_work_started(root, task, flow_id, review_result)
      when is_binary(root) and is_map(task) and is_binary(flow_id) do
    agent_work = result_work(review_result)
    run = result_run(review_result)

    Store.update_task(root, task["id"], fn current ->
      current
      |> update_flow(flow_id, fn flow ->
        flow
        |> Map.put("status", "review_started")
        |> Map.put("review_agent_work_id", agent_work["id"])
        |> Map.put("review_run_id", run["id"])
        |> Map.put("review_agent_work_status", agent_work["status"])
        |> Map.put("review_runtime_status", run["status"])
        |> Map.put("review_started_at", Clock.iso_now())
        |> reject_empty()
      end)
      |> touch()
      |> append_activity("task.mob_colleague_review_started", %{
        "flow_id" => flow_id,
        "review_agent_work_id" => agent_work["id"],
        "review_run_id" => run["id"]
      })
    end)
  end

  def mark_review_agent_work_started(_root, _task, _flow_id, _review_result),
    do: {:error, :invalid_mob_colleague_flow}

  def mark_review_agent_work_failed(root, task, flow_id, reason)
      when is_binary(root) and is_map(task) and is_binary(flow_id) do
    Store.update_task(root, task["id"], fn current ->
      current
      |> update_flow(flow_id, fn flow ->
        flow
        |> Map.put("status", "review_start_failed")
        |> Map.put("review_start_failure", inspect(reason))
        |> Map.put("review_start_failed_at", Clock.iso_now())
        |> reject_empty()
      end)
      |> touch()
      |> append_activity("task.mob_colleague_review_start_failed", %{
        "flow_id" => flow_id,
        "reason" => inspect(reason)
      })
    end)
  end

  def mark_review_agent_work_failed(_root, _task, _flow_id, _reason),
    do: {:error, :invalid_mob_colleague_flow}

  def observation_work_source, do: @observation_work_source
  def review_work_source, do: @review_work_source

  defp normalize_colleague_agent(attrs) do
    with {:ok, agent_id} <- required_text(attrs, "agent_id"),
         {:ok, display_name} <- required_text(attrs, "display_name"),
         {:ok, instructions} <- required_text(attrs, "instructions"),
         {:ok, skills} <- required_nonempty_list(attrs, "skills") do
      roles = normalize_work_roles(Map.get(attrs, "work_roles"))
      metadata = normalize_map(Map.get(attrs, "metadata"))

      {:ok,
       %{
         "agent_id" => agent_id,
         "display_name" => display_name,
         "description" => optional_text(attrs, "description"),
         "agent_handle" => optional_text(attrs, "agent_handle"),
         "agent_ref" => optional_text(attrs, "agent_ref"),
         "status" => optional_text(attrs, "status", "active"),
         "work_roles" => roles,
         "default_work_role" => default_work_role(attrs, roles),
         "skills" => skills,
         "model" => optional_text(attrs, "model"),
         "provider" => optional_text(attrs, "provider"),
         "instructions" => instructions,
         "capabilities" => normalize_string_list(Map.get(attrs, "capabilities")),
         "permissions" => normalize_map(Map.get(attrs, "permissions")),
         "metadata" =>
           Map.merge(metadata, %{
             "source" => "schedule_mob_colleague_flow",
             "mob_colleague" => true
           })
       }
       |> reject_empty()}
    end
  end

  defp normalize_work_roles(value) do
    base_roles =
      value
      |> normalize_string_list()
      |> Enum.filter(&(&1 in Agents.work_roles()))

    Enum.uniq(base_roles ++ ["reviewer", "verifier", "observer"])
  end

  defp default_work_role(attrs, roles) do
    role = optional_text(attrs, "default_work_role", "reviewer")

    if role in roles do
      role
    else
      "reviewer"
    end
  end

  defp required_task_template(attrs, key) do
    with {:ok, template} <- required_map(attrs, key),
         {:ok, title} <- required_text(template, "title"),
         {:ok, description} <- required_text(template, "description") do
      {:ok,
       %{
         "title" => title,
         "description" => description,
         "priority" => optional_text(template, "priority", "medium"),
         "labels" => normalize_labels(Map.get(template, "labels")),
         "agent_policy" => normalize_map(Map.get(template, "agent_policy"))
       }
       |> reject_empty()}
    end
  end

  defp collaboration_comments(attrs) do
    with {:ok, comments} <- required_nonempty_list(attrs, "collaboration_comments") do
      comments
      |> Enum.reduce_while({:ok, []}, fn comment, {:ok, acc} ->
        case normalize_collaboration_comment(comment) do
          {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, normalized} -> ensure_groundwork_comment(normalized)
        error -> error
      end
    end
  end

  defp normalize_collaboration_comment(comment) when is_map(comment) do
    with {:ok, comment} <- canonical_attrs(comment),
         {:ok, body} <- required_text(comment, "body"),
         {:ok, phase} <- comment_phase(comment) do
      {:ok,
       %{
         "body" => body,
         "phase" => phase,
         "priority" => optional_text(comment, "priority"),
         "topic" => optional_text(comment, "topic")
       }
       |> reject_empty()}
    end
  end

  defp normalize_collaboration_comment(_comment), do: {:error, :invalid_collaboration_comment}

  defp comment_phase(comment) do
    case optional_text(comment, "phase", "groundwork") do
      phase when phase in @allowed_comment_phases -> {:ok, phase}
      phase -> {:error, {:invalid_value, "phase", phase, @allowed_comment_phases}}
    end
  end

  defp ensure_groundwork_comment(comments) do
    if Enum.any?(comments, &(&1["phase"] == "groundwork")) do
      {:ok, comments}
    else
      {:error, {:missing_required, "collaboration_comments:groundwork"}}
    end
  end

  defp create_setup_task(parent, profile, template, opts) do
    Repository.create(
      %{
        "title" => template["title"],
        "description" => template["description"],
        "status" => "done",
        "priority" => Map.get(template, "priority", "medium"),
        "parent_id" => parent["id"],
        "origin" => @setup_task_origin,
        "labels" =>
          normalize_labels(Map.get(template, "labels", [])) ++
            [%{"name" => "mob-colleague", "color" => "#2563eb"}],
        "assignees" => [colleague_assignee(profile, "observer")],
        "agent_policy" => Map.get(template, "agent_policy", %{})
      },
      opts
    )
  end

  defp create_observation_task(parent, profile, template, opts) do
    Repository.create(
      %{
        "title" => template["title"],
        "description" => template["description"],
        "status" => "todo",
        "priority" => Map.get(template, "priority", "medium"),
        "parent_id" => parent["id"],
        "origin" => @observation_work_source,
        "labels" =>
          normalize_labels(Map.get(template, "labels", [])) ++
            [%{"name" => "mob-colleague-observation", "color" => "#0891b2"}],
        "assignees" => [colleague_assignee(profile, "observer")],
        "agent_policy" => Map.get(template, "agent_policy", %{})
      },
      opts
    )
  end

  defp arm_flow(
         root,
         parent,
         groundwork_agent_id,
         profile,
         setup_task,
         observation_task,
         observation_task_attrs,
         observation_message,
         review_task_attrs,
         review_message,
         documentation_sources,
         comments
       ) do
    flow_id = Clock.id("mob_colleague_flow")
    now = Clock.iso_now()
    written_comments = Enum.map(comments, &task_comment(&1, flow_id, profile, now))

    flow =
      %{
        "schema_version" => @schema_version,
        "flow_id" => flow_id,
        "status" => "armed",
        "parent_task_id" => parent["id"],
        "parent_task_ref" => parent["ref"],
        "groundwork_agent_id" => groundwork_agent_id,
        "colleague_agent_id" => profile["id"],
        "setup_task_id" => setup_task["id"],
        "setup_task_ref" => setup_task["ref"],
        "observation_task_id" => observation_task["id"],
        "observation_task_ref" => observation_task["ref"],
        "observation_task" => observation_task_attrs,
        "observation_message" => observation_message,
        "review_task" => review_task_attrs,
        "review_message" => review_message,
        "documentation_sources" => documentation_sources,
        "trigger" => %{
          "event" => "agent_work_completed",
          "agent_id" => groundwork_agent_id
        },
        "created_at" => now
      }
      |> reject_empty()

    with {:ok, updated_parent} <-
           Store.update_task(root, parent["id"], fn current ->
             current
             |> Map.update("mob_colleague_flows", [flow], &(&1 ++ [flow]))
             |> Map.update("comments", written_comments, &(&1 ++ written_comments))
             |> touch(now)
             |> append_activity("task.mob_colleague_flow_armed", %{
               "flow_id" => flow_id,
               "groundwork_agent_id" => groundwork_agent_id,
               "colleague_agent_id" => profile["id"],
               "setup_task_id" => setup_task["id"],
               "observation_task_id" => observation_task["id"],
               "comment_ids" => Enum.map(written_comments, & &1["id"])
             })
           end) do
      {:ok, updated_parent, flow, written_comments}
    end
  end

  defp observation_start_request(flow, observation_task) do
    %{
      "flow_id" => flow["flow_id"],
      "observation_task_ref" => observation_task["ref"],
      "agent_work_attrs" =>
        %{
          "agent_ids" => [flow["colleague_agent_id"]],
          "message" => observation_message(flow),
          "source" => @observation_work_source,
          "work_role" => "observer"
        }
        |> reject_empty()
    }
  end

  defp observation_message(flow) do
    sourced_message(flow, "observation_message", """
    Work as a live mob colleague: observe the parent task, inspect its task specs and teammate runtime, check the documentation sources below, and write short course-correction comments to the parent task as soon as you find useful feedback.
    """)
  end

  defp review_message(flow) do
    sourced_message(flow, "review_message", """
    Review the completed groundwork for the parent task. Compare the output against live comments, task specs, teammate runtime, and the documentation sources below. Report concrete quality gaps.
    """)
  end

  defp sourced_message(flow, message_key, purpose) do
    docs =
      flow
      |> Map.get("documentation_sources", [])
      |> case do
        [] ->
          "No explicit documentation sources were provided; inspect task specs and teammate runtime."

        sources ->
          Enum.map_join(sources, "\n", &("- " <> &1))
      end

    """
    #{flow[message_key]}

    Parent task: #{flow["parent_task_ref"]}
    #{String.trim(purpose)}

    Documentation sources:
    #{docs}
    """
    |> String.trim()
  end

  defp task_comment(comment, flow_id, profile, now) do
    %{
      "id" => Clock.id("comment"),
      "body" => comment["body"],
      "author" => "agent:" <> profile["id"],
      "created_at" => now,
      "metadata" => %{
        "schema_version" => @comment_schema_version,
        "kind" => "mob_colleague_feedback",
        "flow_id" => flow_id,
        "colleague_agent_id" => profile["id"],
        "phase" => comment["phase"],
        "priority" => comment["priority"],
        "topic" => comment["topic"]
      }
    }
    |> reject_empty()
  end

  defp create_review_start(root, task, flow, work, run, opts) do
    opts = Keyword.put(opts, :workspace, root)
    profile = %{"id" => flow["colleague_agent_id"], "display_name" => flow["colleague_agent_id"]}
    review_task = normalize_map(flow["review_task"])

    with {:ok, review} <-
           Repository.create(
             %{
               "title" => review_task["title"],
               "description" => review_task["description"],
               "status" => "todo",
               "priority" => Map.get(review_task, "priority", "medium"),
               "parent_id" => task["id"],
               "origin" => @review_work_source,
               "labels" =>
                 normalize_labels(Map.get(review_task, "labels", [])) ++
                   [%{"name" => "mob-colleague-review", "color" => "#7c3aed"}],
               "assignees" => [colleague_assignee(profile, "reviewer")],
               "agent_policy" => Map.get(review_task, "agent_policy", %{})
             },
             opts
           ),
         {:ok, updated_task, comment} <-
           mark_review_task_created(root, task, flow, review, work, run) do
      result =
        %{
          "schema_version" => @trigger_schema_version,
          "flow_id" => flow["flow_id"],
          "status" => "review_task_created",
          "review_task_id" => review["id"],
          "review_task_ref" => review["ref"],
          "review_comment_id" => comment["id"]
        }
        |> reject_empty()

      start_request =
        %{
          "flow_id" => flow["flow_id"],
          "review_task_ref" => review["ref"],
          "agent_work_attrs" =>
            %{
              "agent_ids" => [flow["colleague_agent_id"]],
              "message" => review_message(flow),
              "source" => @review_work_source,
              "work_role" => "reviewer"
            }
            |> reject_empty()
        }

      {:ok, updated_task, result, start_request}
    end
  end

  defp mark_review_task_created(root, task, flow, review, work, run) do
    now = Clock.iso_now()

    comment =
      %{
        "id" => Clock.id("comment"),
        "body" =>
          "Mob colleague #{flow["colleague_agent_id"]} opened review task #{review["ref"]}.",
        "author" => "agent:" <> flow["colleague_agent_id"],
        "created_at" => now,
        "metadata" => %{
          "schema_version" => @comment_schema_version,
          "kind" => "mob_colleague_review_started",
          "flow_id" => flow["flow_id"],
          "colleague_agent_id" => flow["colleague_agent_id"],
          "review_task_id" => review["id"],
          "review_task_ref" => review["ref"],
          "groundwork_agent_work_id" => work["id"],
          "groundwork_run_id" => run["id"]
        }
      }
      |> reject_empty()

    with {:ok, updated_task} <-
           Store.update_task(root, task["id"], fn current ->
             current
             |> update_flow(flow["flow_id"], fn current_flow ->
               current_flow
               |> Map.put("status", "review_task_created")
               |> Map.put("review_task_id", review["id"])
               |> Map.put("review_task_ref", review["ref"])
               |> Map.put("groundwork_agent_work_id", work["id"])
               |> Map.put("groundwork_run_id", run["id"])
               |> Map.put("review_task_created_at", now)
               |> reject_empty()
             end)
             |> Map.update("comments", [comment], &(&1 ++ [comment]))
             |> touch(now)
             |> append_activity("task.mob_colleague_review_task_created", %{
               "flow_id" => flow["flow_id"],
               "review_task_id" => review["id"],
               "review_task_ref" => review["ref"],
               "groundwork_agent_work_id" => work["id"]
             })
           end) do
      {:ok, updated_task, comment}
    end
  end

  defp mark_flow_failed(root, task, flow, reason) do
    with {:ok, updated_task} <-
           Store.update_task(root, task["id"], fn current ->
             current
             |> update_flow(flow["flow_id"], fn current_flow ->
               current_flow
               |> Map.put("status", "review_task_failed")
               |> Map.put("review_task_failure", inspect(reason))
               |> Map.put("review_task_failed_at", Clock.iso_now())
               |> reject_empty()
             end)
             |> touch()
             |> append_activity("task.mob_colleague_review_task_failed", %{
               "flow_id" => flow["flow_id"],
               "reason" => inspect(reason)
             })
           end) do
      {:ok, updated_task, failed_trigger_result(flow, reason)}
    end
  end

  defp failed_trigger_result(flow, reason) do
    %{
      "schema_version" => @trigger_schema_version,
      "flow_id" => flow["flow_id"],
      "status" => "review_task_failed",
      "reason" => inspect(reason)
    }
  end

  defp matching_armed_flows(task, work) do
    work_agent_ids = work_agent_ids(work)

    task
    |> Map.get("mob_colleague_flows", [])
    |> Enum.filter(fn flow ->
      is_map(flow) and flow["status"] in ["armed", "observing"] and
        flow["groundwork_agent_id"] in work_agent_ids
    end)
  end

  defp work_agent_ids(work) do
    (normalize_string_list(work["agent_ids"]) ++ normalize_string_list(work["agent_id"]))
    |> Enum.uniq()
  end

  defp triggering_work?(%{"source" => @review_work_source}), do: false
  defp triggering_work?(%{"source" => @observation_work_source}), do: false
  defp triggering_work?(%{"status" => "awaiting_verification"}), do: true
  defp triggering_work?(_work), do: false

  defp update_flow(task, flow_id, fun) do
    Map.update(task, "mob_colleague_flows", [], fn flows ->
      Enum.map(flows, fn
        %{"flow_id" => ^flow_id} = flow -> fun.(flow)
        flow -> flow
      end)
    end)
  end

  defp colleague_assignee(profile, work_role) do
    %{
      "id" => profile["id"],
      "agent_id" => profile["id"],
      "kind" => "agent",
      "display_name" => colleague_display_name(profile),
      "work_role" => work_role
    }
    |> reject_empty()
  end

  defp colleague_display_name(profile) do
    case profile["display_name"] do
      value when value in [nil, ""] -> profile["id"]
      value -> value
    end
  end

  defp reject_obsolete_keys(attrs, keys, scope) do
    found = Enum.filter(keys, &Map.has_key?(attrs, &1))

    if found == [] do
      :ok
    else
      {:error,
       %{
         "code" => "obsolete_mob_colleague_fields",
         "scope" => scope,
         "fields" => found
       }}
    end
  end

  defp required_map(attrs, key) do
    case Map.get(attrs, key) do
      value when is_map(value) -> canonical_attrs(value)
      _value -> {:error, {:missing_required, key}}
    end
  end

  defp required_nonempty_list(attrs, key) do
    case Map.get(attrs, key) do
      value when is_list(value) and value != [] ->
        {:ok, value}

      _value ->
        {:error, {:missing_required, key}}
    end
  end

  defp required_text(attrs, key), do: Attributes.required_text(attrs, key)

  defp optional_text(attrs, key, default \\ nil),
    do: Attributes.optional_text(attrs, key, default)

  defp normalize_string_list(value), do: Attributes.normalize_string_list(value)
  defp normalize_labels(value), do: Attributes.normalize_labels(value)
  defp reject_empty(map), do: Attributes.reject_empty(map)

  defp result_work(%{agent_work: work}) when is_map(work), do: work

  defp result_work(result),
    do: raise(ArgumentError, "mob colleague result missing :agent_work: #{inspect(result)}")

  defp result_run(%{run: run}) when is_map(run), do: run

  defp result_run(result),
    do: raise(ArgumentError, "mob colleague result missing :run: #{inspect(result)}")

  defp normalize_map(value) when is_map(value) do
    if canonical_map?(value), do: value, else: %{}
  end

  defp normalize_map(_value), do: %{}

  defp canonical_attrs(attrs) do
    if canonical_map?(attrs), do: {:ok, attrs}, else: {:error, :invalid_attrs}
  end

  defp canonical_map?(attrs), do: Attributes.canonical_map?(attrs)

  defp touch(task, now \\ Clock.iso_now()), do: Map.put(task, "updated_at", now)

  defp append_activity(task, type, data) do
    event =
      data
      |> reject_empty()
      |> Map.put("type", type)
      |> Map.put_new("at", Clock.iso_now())

    Map.update(task, "activity", [event], &(&1 ++ [event]))
  end
end
