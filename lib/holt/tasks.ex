defmodule Holt.Tasks do
  @moduledoc """
  Workspace-local task flow with durable artifacts and run linkage.
  """

  alias Holt.{Actions, Agents, Clock, JSON, Paths, ResearchClaims, Runtime}

  alias Holt.Tasks.{
    ActionContract,
    ActionPreflight,
    ActionRuntimeEnvelope,
    AgentDispatch,
    AgentLoop,
    AgentRunDecision,
    AgentRunFailureClassifier,
    AgentRunPolicy,
    AgentRuns,
    AgentRunStateMachine,
    AgentWorkLiveness,
    CapabilityContract,
    CapabilityRegistry,
    CapabilityRouter,
    ChildAgentContract,
    ConsequenceGate,
    ContextBudget,
    ContextBudgetGovernor,
    ContinuationPacket,
    EvidenceLedger,
    EvidenceContract,
    GenericPlanner,
    HumanApprovalInbox,
    MetaLearningLoop,
    PlanContract,
    PlanGate,
    ProviderRegistry,
    ProcessWakeScheduler,
    RecoveryContract,
    RunDebugger,
    SafetyPolicy,
    TaskMemory,
    TaskGraphs,
    TaskToolRouter,
    TaskToolSession,
    TeamOrchestration,
    ToolRegistry,
    VerificationContract,
    VerificationGateway,
    VerifierAssignment,
    VerifierCalibration,
    VerifierDispatcher,
    VerifierRouting,
    WorkGraph,
    WorkGraphBudget,
    WorkGraphScheduler
  }

  @statuses ~w(backlog todo in_progress waiting done canceled)
  @kinds ~w(task epic)
  @priorities ~w(urgent high medium low)
  @agent_modes ~w(work concept deep_concept)
  @default_agent_id "default"
  @watchdog_recovery_source "task_agent_watchdog_recovery"
  @process_wake_source "task_agent_process_wake"
  @watchdog_stale_after_seconds 300
  @watchdog_recovery_cooldown_seconds 600
  @verification_statuses ~w(passed failed blocked skipped needs_review)
  @link_types ~w(blocks depends_on causes relates_to duplicates clones implements tests fixes tracks)
  @estimates [nil, 1, 2, 3, 5, 8, 13]
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

  def statuses, do: @statuses
  def kinds, do: @kinds
  def priorities, do: @priorities
  def spec_kinds, do: @spec_kinds
  def link_types, do: @link_types
  def estimates, do: @estimates
  def runtime_spec_kinds, do: @runtime_spec_kinds
  def memory_kinds, do: @memory_kinds

  def agents(opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> Agents.list_for_root()
  end

  def create_agent(attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.create(attrs)
  end

  def update_agent(agent_id, attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.update(agent_id, attrs)
  end

  def get_agent(agent_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> Agents.get(agent_id)
  end

  def suspend_agent(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.suspend(agent_id, attrs)
  end

  def resume_agent(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.resume(agent_id, attrs)
  end

  def archive_agent(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.archive(agent_id, attrs)
  end

  def agent_cards(opts \\ []) do
    root = Paths.workspace_root(opts)
    Agents.list_cards(root, opts)
  end

  def agent_card(agent_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> Agents.card(agent_id)
  end

  def agent_skills(agent_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> Agents.list_skills(agent_id)
  end

  def action_definitions(opts \\ []), do: Actions.definitions(opts)

  def action_catalog(context \\ %{}, opts \\ []), do: Actions.agent_tool_catalog(context, opts)

  def agent_tool_definitions(context \\ %{}, opts \\ []),
    do: Actions.agent_tool_definitions(context, opts)

  def action_provider_metadata(context \\ %{}, opts \\ []),
    do: Actions.tool_provider_metadata(context, opts)

  def action_provider_prompt_sections(context \\ %{}, opts \\ []),
    do: Actions.action_provider_prompt_sections(context, opts)

  def search_actions(filters \\ %{}, opts \\ []) when is_map(filters),
    do: Actions.search(filters, opts)

  def get_action(name, opts \\ []), do: Actions.get(name, opts)

  def execute_action(name, args \\ %{}, opts \\ []) when is_map(args),
    do: Actions.execute(name, args, opts)

  def dispatch_agent_tool(name, args \\ %{}, context \\ %{}, opts \\ []) when is_map(args),
    do: Actions.dispatch_agent_tool(name, args, context, opts)

  def execute_task_action(ref_or_id, tool_name, args \\ %{}, opts \\ []) when is_map(args),
    do: Actions.execute_task_tool(ref_or_id, tool_name, args, opts)

  def execute_task_actions(ref_or_id, calls, opts \\ []) when is_list(calls),
    do: Actions.execute_many(ref_or_id, calls, opts)

  def tool_availability(attrs \\ %{}) when is_map(attrs), do: ToolRegistry.snapshot(attrs)

  def provider_profile(model_id, attrs \\ %{}) when is_map(attrs),
    do: ProviderRegistry.profile(model_id, attrs)

  def research_claims(opts \\ []), do: ResearchClaims.list(opts)

  def safety_policy(attrs \\ %{}) when is_map(attrs), do: SafetyPolicy.build(attrs)

  def runtime_context_budget(attrs \\ %{}) when is_map(attrs), do: ContextBudget.build(attrs)

  def recovery_contract(attrs \\ %{}) when is_map(attrs), do: RecoveryContract.build(attrs)

  def run_debugger(attrs \\ %{}) when is_map(attrs), do: RunDebugger.build(attrs)

  def meta_learning_snapshot(attrs \\ %{}) when is_map(attrs), do: MetaLearningLoop.build(attrs)

  def agent_run_lifecycle_states, do: AgentRunStateMachine.states()

  def agent_run_lifecycle_transition(current_state, next_state),
    do: AgentRunStateMachine.transition(current_state, next_state)

  def agent_run_lifecycle_complete(attrs \\ %{}) when is_map(attrs),
    do: AgentRunStateMachine.complete(attrs)

  def agent_loop_contract(attrs \\ %{}) when is_map(attrs), do: AgentLoop.contract(attrs)

  def record_process_started(payload, context \\ %{}, opts \\ [])

  def record_process_started(payload, context, opts) when is_map(payload) and is_map(context),
    do: ProcessWakeScheduler.record_started(string_keys(payload), string_keys(context), opts)

  def record_process_started(_payload, _context, _opts), do: {:error, :invalid_process_event}

  def notify_process_terminal(payload, context \\ %{}, opts \\ [])

  def notify_process_terminal(payload, context, opts) when is_map(payload) and is_map(context),
    do: ProcessWakeScheduler.notify_terminal(string_keys(payload), string_keys(context), opts)

  def notify_process_terminal(_payload, _context, _opts), do: {:error, :invalid_process_event}

  def runtime_doctor(attrs \\ %{}) when is_map(attrs) do
    tools = tool_availability(attrs)
    status = if Enum.all?(tools, & &1["available"]), do: "ready", else: "degraded"

    %{
      "schema_version" => "holtworks_agent_runtime_doctor/v1",
      "status" => status,
      "tools" => tools
    }
  end

  def create(attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)
    ensure_store(root)

    with {:ok, title} <- required_text(attrs, "title"),
         {:ok, kind} <- enum_value(attrs, "kind", @kinds, "task"),
         {:ok, status} <- enum_value(attrs, "status", @statuses, "todo"),
         {:ok, priority} <- enum_value(attrs, "priority", @priorities, "medium"),
         {:ok, estimate} <- estimate_value(Map.get(attrs, "estimate", nil)),
         {:ok, number} <- next_number(root) do
      now = Clock.iso_now()

      task =
        %{
          "schema_version" => "holtworks_task/v1",
          "id" => Clock.id("task"),
          "number" => number,
          "ref" => task_ref(number),
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
      |> load_tasks()
      |> Kernel.++([task])
      |> store_tasks(root)

      {:ok, task}
    end
  end

  def list(opts \\ []) do
    root = Paths.workspace_root(opts)
    status = option(opts, :status)

    root
    |> load_tasks()
    |> filter_status(status)
    |> Enum.sort_by(&Map.get(&1, "number", 0))
    |> Enum.map(&enrich_task(root, &1))
  end

  def get(ref_or_id, opts \\ []) do
    root = Paths.workspace_root(opts)

    case Enum.find(load_tasks(root), &task_ref_matches?(&1, ref_or_id)) do
      nil -> {:error, :task_not_found}
      task -> {:ok, enrich_task(root, task)}
    end
  end

  def update(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, patch} <- update_patch(attrs),
         {:ok, task} <-
           update_task(root, ref_or_id, fn task ->
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
           update_task(root, ref_or_id, fn task ->
             comment = %{
               "id" => Clock.id("comment"),
               "body" => text,
               "author" => opts[:author] || "user",
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
      update_task(root, task["id"], fn current ->
        next_comments = Enum.reject(current["comments"] || [], &(&1["id"] == comment_id))

        current
        |> Map.put("comments", next_comments)
        |> touch()
        |> append_activity("task.comment_deleted", %{"comment_id" => comment_id})
      end)
    end
  end

  def add_label(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, name} <- required_text(attrs, "name") do
      color = optional_text(attrs, "color", "#2563eb")
      label = %{"name" => name, "color" => color}

      update_task(root, ref_or_id, fn task ->
        labels = normalize_labels(task["labels"] || [])

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
    normalized = normalize_label_name(name)

    update_task(root, ref_or_id, fn task ->
      labels = normalize_labels(task["labels"] || [])
      next_labels = Enum.reject(labels, &(normalize_label_name(&1["name"]) == normalized))

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

      update_task(root, source["id"], fn task ->
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
      update_task(root, task["id"], fn current ->
        next_links = Enum.reject(current["links"] || [], &(&1["id"] == link_id))

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
    attrs = string_keys(attrs)
    ensure_store(root)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, kind} <- enum_value(attrs, "kind", @spec_kinds, nil),
         {:ok, content} <- required_text(attrs, "content") do
      spec_id = Clock.id("spec")
      title = optional_text(attrs, "title", default_spec_title(kind, task))
      relative_path = Path.join([".holtworks", "tasks", "specs", task["id"], spec_id <> ".md"])
      absolute_path = Path.join(root, relative_path)
      now = Clock.iso_now()

      spec =
        %{
          "schema_version" => "holtworks_task_spec/v1",
          "id" => spec_id,
          "task_id" => task["id"],
          "task_ref" => task["ref"],
          "kind" => kind,
          "title" => title,
          "path" => relative_path,
          "created_at" => now,
          "created_by" => opts[:author] || "user",
          "metadata" => normalize_metadata(Map.get(attrs, "metadata", %{}))
        }

      File.mkdir_p!(Path.dirname(absolute_path))
      File.write!(absolute_path, content)

      root
      |> load_specs()
      |> Kernel.++([spec])
      |> store_specs(root)

      attachment =
        %{
          "id" => spec_id,
          "kind" => "spec",
          "artifact_kind" => kind,
          "spec_kind" => kind,
          "title" => title,
          "path" => relative_path
        }

      {:ok, updated_task} =
        update_task(root, task["id"], fn current ->
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
      kind = option(opts, :kind) || "all"
      include_content? = option(opts, :include_content) != false
      content_limit = option(opts, :content_limit) || 12_000

      specs =
        root
        |> load_specs()
        |> Enum.filter(&(&1["task_id"] == task["id"]))
        |> filter_spec_kind(kind)
        |> Enum.map(&maybe_include_spec_content(&1, root, include_content?, content_limit))

      {:ok, specs}
    end
  end

  def get_spec(spec_id, opts \\ []) do
    root = Paths.workspace_root(opts)
    task_ref = option(opts, :task_ref) || option(opts, :task_id)

    case Enum.find(load_specs(root), &(&1["id"] == spec_id)) do
      nil ->
        {:error, :spec_not_found}

      spec ->
        with :ok <- ensure_spec_task_scope(spec, task_ref, opts) do
          {:ok,
           maybe_include_spec_content(spec, root, true, option(opts, :content_limit) || 50_000)}
        end
    end
  end

  def save_teammate_memory(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, memory_attrs} <- teammate_memory_attrs(attrs) do
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
               content_limit: option(opts, :content_limit) || 1_600
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
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, artifact} <- TaskMemory.record_artifact(root, task, attrs),
         {:ok, updated_task} <-
           update_task(root, task["id"], fn current ->
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
      {:ok, Map.put(artifact, "task", enrich_task(root, updated_task))}
    end
  end

  def task_memory_context(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts) do
      TaskMemory.context_packet(root, task, task_memory_context_attrs(root, task, attrs, opts))
    end
  end

  def context_budget(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, _task} <- get(ref_or_id, opts) do
      if Map.has_key?(attrs, "messages") or Map.has_key?(attrs, "estimated_input_tokens") do
        {:ok, ContextBudgetGovernor.plan(attrs)}
      else
        with {:ok, packet} <- task_memory_context(ref_or_id, attrs, opts) do
          {:ok, packet["context_budget"]}
        end
      end
    end
  end

  def continuation_packet(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, previous_work} <- agent_work_to_continue(task, attrs) do
      previous_run = agent_run_for_work(root, task["id"], previous_work)
      context_packet = task_memory_context_packet(root, task, attrs, opts)

      {:ok,
       build_continuation_packet(task, previous_work, previous_run, context_packet, attrs, opts)}
    end
  end

  def agent_runs(opts \\ []) do
    AgentRuns.list(opts)
  end

  def agent_run_events(opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.event_log()
  end

  def agent_run_event_log(run_or_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.list_events(run_or_id)
  end

  def agent_runs_by_agent(agent_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.list_by_agent(agent_id, opts)
  end

  def agent_run_events_by_agent(agent_id, filters \\ %{}, opts \\ []) when is_map(filters) do
    root = Paths.workspace_root(opts)
    AgentRuns.search_events_by_agent(root, agent_id, string_keys(filters))
  end

  def agent_run_replay(agent_id, run_or_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.replay_by_agent(agent_id, run_or_id)
  end

  def agent_run_task_inspector(task_ref_or_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.task_inspector(task_ref_or_id, opts)
  end

  def record_agent_run_event(run_or_id, attrs, opts \\ [])

  def record_agent_run_event(run_or_id, attrs, opts) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)
    metadata = Map.get(attrs, "metadata", Map.drop(attrs, ["kind", "type", "message"]))

    AgentRuns.record_event_once(
      root,
      run_or_id,
      attrs["kind"] || attrs["type"] || "agent_run.event",
      attrs["message"] || "Agent run event recorded.",
      metadata
    )
  end

  def record_agent_run_event(_run_or_id, _attrs, _opts),
    do: {:error, :invalid_agent_run_event}

  def record_agent_run_continuation_packet(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_continuation_packet(run_or_id, attrs)
  end

  def record_agent_run_narration(run_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_agent_narration(run_or_id, attrs)
  end

  def record_agent_run_plan_contract(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_plan_contract(run_or_id, attrs)
  end

  def record_agent_run_child_contract(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_child_agent_contract(run_or_id, attrs)
  end

  def record_agent_run_child_completion(run_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_child_agent_completion(run_or_id, attrs)
  end

  def record_agent_run_tool_event(run_or_id, attrs, opts \\ [])

  def record_agent_run_tool_event(run_or_id, attrs, opts) when is_map(attrs) do
    attrs = string_keys(attrs)
    tool_name = attrs["tool_name"] || attrs["tool"]
    tool_call_id = attrs["tool_call_id"] || attrs["call_id"] || Clock.id("tool_call")

    result =
      attrs["result"] ||
        %{
          "status" => attrs["result_status"] || attrs["status"],
          "preview" => attrs["result_preview"]
        }
        |> reject_empty()

    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_tool_event(run_or_id, tool_name, tool_call_id, result, attrs)
  end

  def record_agent_run_tool_event(_run_or_id, _attrs, _opts), do: {:error, :invalid_tool_event}

  def record_agent_run_objective_evaluation(run_or_id, attrs, opts \\ [])

  def record_agent_run_objective_evaluation(run_or_id, attrs, opts) when is_map(attrs) do
    attrs = string_keys(attrs)

    route =
      attrs["route"] || attrs["evaluation"] ||
        Map.take(attrs, ["can_finish", "decision", "status"])

    opts
    |> Paths.workspace_root()
    |> AgentRuns.record_objective_evaluation(run_or_id, route, attrs)
  end

  def record_agent_run_objective_evaluation(_run_or_id, _attrs, _opts),
    do: {:error, :invalid_objective_evaluation}

  def task_graphs(ref_or_id, opts \\ []) do
    root = Paths.workspace_root(opts)

    with {:ok, task} <- get(ref_or_id, opts) do
      {:ok, TaskGraphs.list_for_task(root, task["id"])}
    end
  end

  def get_task_graph(graph_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> TaskGraphs.get(graph_id)
  end

  def create_task_graph(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, task} <- get(ref_or_id, opts) do
      TaskGraphs.create(root, task, attrs)
    end
  end

  def advance_task_graph(graph_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> TaskGraphs.advance(graph_id, attrs)
  end

  def complete_task_graph_node(graph_id, node_ref, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> TaskGraphs.complete_node(graph_id, node_ref, attrs)
  end

  def block_task_graph_node(graph_id, node_ref, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> TaskGraphs.block_node(graph_id, node_ref, attrs)
  end

  def evidence_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts) do
      {:ok, evidence_contract_for_task(root, task, attrs)}
    end
  end

  def verification_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts) do
      {:ok,
       VerificationContract.build(
         attrs
         |> Map.put("task", task)
         |> Map.put("evidence_contract", evidence_contract_for_task(root, task, attrs))
       )}
    end
  end

  def plan_verifier_route(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, graph} <- verifier_route_graph(root, task, attrs) do
      contract = evidence_contract_for_task(root, task, attrs)

      route =
        VerifierRouting.plan(%{
          "task" => task,
          "task_graph" => graph,
          "task_graph_gate" => graph["mission_control"],
          "evidence_contract" => contract,
          "available_agents" => verifier_available_agents(root, task, attrs)
        })

      {:ok, routed_graph} = TaskGraphs.record_verifier_route(root, graph["id"], route)

      {:ok, updated_task} =
        update_task(root, task["id"], fn current ->
          current
          |> touch()
          |> append_activity("task.verifier_route_planned", %{
            "route_id" => route["route_id"],
            "graph_id" => graph["id"],
            "status" => route["status"],
            "target_agent_id" => route["target_agent_id"]
          })
        end)

      {:ok, %{task: enrich_task(root, updated_task), route: route, task_graph: routed_graph}}
    end
  end

  def verifier_assignment(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, graph} <- work_graph(ref_or_id, attrs, opts) do
      evidence_contract = evidence_contract_for_task(root, task, attrs)
      {:ok, verification_contract} = verification_contract(ref_or_id, attrs, opts)

      {:ok,
       VerifierAssignment.assign(
         attrs
         |> Map.put("task", task)
         |> Map.put("work_graph", graph)
         |> Map.put("work_graph_gate", graph["completion_gate"])
         |> Map.put("evidence_contract", evidence_contract)
         |> Map.put("verification_contract", verification_contract)
         |> Map.put("available_agents", verifier_available_agents(root, task, attrs))
         |> Map.put_new("verifier_quality", verifier_quality_records(root))
       )}
    end
  end

  def verifier_dispatch(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, graph} <- work_graph(ref_or_id, attrs, opts),
         {:ok, assignment} <- verifier_assignment(ref_or_id, attrs, opts),
         {:ok, contract} <- verification_contract(ref_or_id, attrs, opts) do
      evidence_contract = evidence_contract_for_task(root, task, attrs)

      {:ok,
       VerifierDispatcher.build(
         attrs
         |> Map.put("task", task)
         |> Map.put("work_graph", graph)
         |> Map.put("work_graph_gate", graph["completion_gate"])
         |> Map.put("evidence_contract", evidence_contract)
         |> Map.put("verification_contract", contract)
         |> Map.put("verifier_assignment", assignment)
       )}
    end
  end

  def verifier_calibration(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, _task} <- get(ref_or_id, opts),
         {:ok, assignment} <- calibration_assignment(ref_or_id, attrs, opts),
         {:ok, graph} <- work_graph(ref_or_id, attrs, opts) do
      calibration =
        attrs
        |> Map.put("verifier_assignment", assignment)
        |> Map.put("work_graph_gate", graph["completion_gate"])
        |> VerifierCalibration.build()
        |> persist_verifier_calibration(root)

      {:ok, calibration}
    end
  end

  def verifier_calibrations(opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> load_verifier_calibrations()
  end

  def task_tool_session(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts) do
      {:ok,
       TaskToolSession.build(
         attrs
         |> Map.put("task", task)
         |> Map.put("workspace", root)
       )}
    end
  end

  def task_tool_session_prompt(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, session} <- task_tool_session(ref_or_id, attrs, opts) do
      {:ok, TaskToolSession.prompt_section(session)}
    end
  end

  def action_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, session} <- route_task_tool_session(ref_or_id, attrs, opts) do
      {:ok,
       ActionContract.build(
         attrs
         |> Map.put("task_tool_session", session)
         |> Map.put_new("tool_name", attrs["name"])
       )}
    end
  end

  def route_task_tool(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, session} <- route_task_tool_session(ref_or_id, attrs, opts) do
      {:ok,
       TaskToolRouter.route(
         attrs
         |> Map.put("task_tool_session", session)
         |> Map.put_new("tool_name", attrs["name"])
       )}
    end
  end

  def plan_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, session} <- route_task_tool_session(ref_or_id, attrs, opts),
         {:ok, graph} <- maybe_plan_graph(root, task, attrs) do
      contract_attrs =
        attrs
        |> Map.put("task", task)
        |> Map.put("workspace", root)
        |> Map.put("task_tool_session", session)
        |> Map.put("evidence_contract", evidence_contract_for_task(root, task, attrs))

      contract_attrs =
        if graph do
          Map.put(contract_attrs, "task_graph", graph)
        else
          contract_attrs
        end

      {:ok, PlanContract.build(contract_attrs)}
    end
  end

  def plan_gate(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, route} <- route_task_tool(ref_or_id, attrs, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      {:ok,
       PlanGate.evaluate(%{
         "task_tool_route" => route,
         "action_contract" => route["action_contract"],
         "plan_contract" => plan
       })}
    end
  end

  def action_preflight(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, route} <- route_task_tool(ref_or_id, attrs, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      gate =
        PlanGate.evaluate(%{
          "task_tool_route" => route,
          "action_contract" => route["action_contract"],
          "plan_contract" => plan
        })

      {:ok,
       ActionPreflight.evaluate(
         attrs
         |> Map.put("task_tool_route", route)
         |> Map.put("action_contract", route["action_contract"])
         |> Map.put("plan_contract", plan)
         |> Map.put("plan_gate", gate)
       )}
    end
  end

  def consequence_gate(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, runtime_attrs} <- action_runtime_attrs(ref_or_id, attrs, opts) do
      {:ok, ConsequenceGate.evaluate(runtime_attrs)}
    end
  end

  def action_runtime_envelope(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, runtime_attrs} <- action_runtime_attrs(ref_or_id, attrs, opts) do
      {:ok, ActionRuntimeEnvelope.propose(runtime_attrs)}
    end
  end

  def capability_registry(tool_name, attrs \\ %{}) when is_map(attrs) do
    {:ok, CapabilityRegistry.lookup(tool_name, attrs)}
  end

  def capability_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, capability_attrs} <- capability_attrs(ref_or_id, attrs, opts) do
      {:ok, CapabilityContract.build(capability_attrs)}
    end
  end

  def capability_route(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, contract} <- capability_contract(ref_or_id, attrs, opts) do
      route_attrs =
        attrs
        |> string_keys()
        |> Map.put("capability_contract", contract)
        |> Map.put("available_agents", available_capability_agents(task, attrs))

      {:ok, CapabilityRouter.route(route_attrs)}
    end
  end

  def generic_plan(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, capability_attrs} <- capability_attrs(ref_or_id, attrs, opts) do
      {:ok, GenericPlanner.build(capability_attrs)}
    end
  end

  def work_graph(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, task_graph} <- maybe_plan_graph(root, task, attrs) do
      agent_runs = AgentRuns.list_for_task(task["id"], workspace: root)

      {:ok,
       WorkGraph.build(%{
         "task" => task,
         "task_graph" => task_graph,
         "agent_runs" => agent_runs,
         "events" => agent_run_events_for_task(root, task),
         "verification_gate" => graph_gate(task_graph) || latest_verification_gate(agent_runs),
         "child_agent_contracts" => attrs["child_agent_contracts"],
         "prediction_errors" => attrs["prediction_errors"]
       })}
    end
  end

  def work_graph_gate(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, graph} <- work_graph(ref_or_id, attrs, opts) do
      {:ok,
       WorkGraph.completion_gate(%{
         "work_graph" => graph,
         "verification_gate" => graph["completion_gate"]
       })}
    end
  end

  def work_graph_budget(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, targets} <- resolve_agent_work_targets(root, task, attrs) do
      {:ok,
       WorkGraphBudget.build(
         attrs
         |> Map.put("task", task)
         |> Map.put("task_id", task["id"])
         |> Map.put("task_ref", task["ref"])
         |> Map.put("candidate_agents", targets)
       )}
    end
  end

  def work_graph_schedule(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, graph} <- work_graph(ref_or_id, attrs, opts) do
      {:ok,
       WorkGraphScheduler.schedule(
         attrs
         |> Map.put("work_graph", graph)
         |> Map.put("verification_gate", graph["completion_gate"])
       )}
    end
  end

  def agent_dispatch_plan(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, targets} <- resolve_agent_work_targets(root, task, attrs) do
      {:ok, agent_work_dispatch_plan(task, targets, attrs, opts)}
    end
  end

  def team_orchestration(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts) do
      {:ok,
       TeamOrchestration.plan(
         attrs
         |> Map.put("task", task)
         |> Map.put_new("estimate", task["estimate"])
       )}
    end
  end

  def child_agent_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      action =
        case action_contract_for_child(ref_or_id, attrs, opts) do
          {:ok, contract} -> contract
          {:error, _reason} -> %{}
        end

      {:ok,
       ChildAgentContract.build(
         attrs
         |> Map.put("task", task)
         |> Map.put("plan_contract", plan)
         |> Map.put("action_contract", action)
         |> Map.put(
           "evidence_contract",
           evidence_contract_for_task(Paths.workspace_root(opts), task, attrs)
         )
         |> Map.put("context", child_agent_context(task, attrs))
       )}
    end
  end

  def complete_action_runtime_envelope(envelope, attrs \\ %{})

  def complete_action_runtime_envelope(envelope, attrs) when is_map(envelope) and is_map(attrs) do
    {:ok, ActionRuntimeEnvelope.complete(envelope, attrs)}
  end

  def complete_action_runtime_envelope(_envelope, _attrs), do: {:error, :invalid_envelope}

  def action_approval_request(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, envelope} <- action_runtime_envelope(ref_or_id, attrs, opts) do
      request =
        attrs
        |> Map.put("action_runtime_envelope", envelope)
        |> HumanApprovalInbox.build_request()

      record =
        if request do
          request =
            request
            |> Map.put("task_ref", envelope_task_ref(envelope))
            |> Map.put("task_id", envelope_task_id(envelope))

          persist_action_approval_request(root, request)
        else
          HumanApprovalInbox.not_required(envelope)
        end

      maybe_record_approval_memory(root, record)
      {:ok, record}
    end
  end

  def resolve_action_approval_request(request_or_id, attrs \\ %{}, opts \\ [])

  def resolve_action_approval_request(request, attrs, opts)
      when is_map(request) and is_map(attrs) do
    root = Paths.workspace_root(opts)
    request = string_keys(request)
    resolution = HumanApprovalInbox.resolve(request, attrs)
    {:ok, persist_action_approval_resolution(root, request, resolution)}
  end

  def resolve_action_approval_request(request_id, attrs, opts)
      when is_binary(request_id) and is_map(attrs) do
    root = Paths.workspace_root(opts)

    case find_action_approval_request(root, request_id) do
      nil ->
        {:error, :approval_request_not_found}

      request ->
        resolution = HumanApprovalInbox.resolve(request, attrs)
        {:ok, persist_action_approval_resolution(root, request, resolution)}
    end
  end

  def resolve_action_approval_request(_request_or_id, _attrs, _opts),
    do: {:error, :invalid_approval_request}

  def action_evidence_ledger(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, envelope} <- evidence_envelope(ref_or_id, attrs, opts) do
      request =
        case Map.get(attrs, "approval_request") do
          request when is_map(request) -> request
          _missing -> nil
        end

      ledger =
        attrs
        |> Map.put("task_id", task["id"])
        |> Map.put("task_ref", task["ref"])
        |> Map.put("action_runtime_envelope", envelope)
        |> maybe_put_evidence_approval_request(request)
        |> EvidenceLedger.build()
        |> Map.put("task_id", task["id"])
        |> Map.put("task_ref", task["ref"])

      ledger = persist_action_evidence_ledger(root, ledger)
      maybe_record_ledger_memory(root, task, ledger)
      {:ok, ledger}
    end
  end

  def watchdog_scan(opts \\ []) do
    root = Paths.workspace_root(opts)
    ensure_store(root)

    limit = positive_integer(option(opts, :limit), 50)

    AgentRuns.list(workspace: root)
    |> Enum.filter(&watchdog_candidate?/1)
    |> Enum.take(limit)
    |> Enum.map(&evaluate_watchdog_run(root, &1, opts))
  end

  def queue_process_wake_continuation(root, run, event, payload, opts \\ [])

  def queue_process_wake_continuation(root, run, event, payload, opts)
      when is_binary(root) and is_map(run) and is_map(event) and is_map(payload) do
    reason = process_wake_reason(event, payload)

    with {:ok, task} <- get(run["task_id"], workspace: root),
         :ok <- ensure_latest_watchdog_run(root, run),
         :ok <- ensure_watchdog_task_open(task),
         :ok <- ensure_no_other_active_agent_work(task, run),
         packet = process_wake_packet(task, run, event, payload, reason),
         {:ok, marked_task} <- mark_task_process_wake(root, task, run, packet, reason),
         {:ok, marked_run, wake_event} <-
           AgentRuns.mark_process_wake_queued(root, run, packet, reason),
         {:ok, result} <-
           maybe_start_process_wake_continuation(
             marked_task,
             marked_run,
             packet,
             wake_event,
             opts
           ) do
      {:ok,
       result
       |> Map.put_new("agent_run_id", run["id"])
       |> Map.put_new("task_ref", task["ref"])
       |> Map.put_new("agent_id", run["agent_id"])
       |> Map.put_new("action", "wake_queued")
       |> Map.put_new("reason", reason)
       |> Map.put_new("process_event_id", event["id"])
       |> Map.put_new("process_wake_event_id", wake_event["id"])
       |> Map.put_new("process_wake_packet", packet)}
    else
      {:error, error_reason} ->
        packet = process_wake_packet(%{}, run, event, payload, reason)
        {:ok, _record} = AgentRuns.mark_process_wake_failed(root, run, packet, error_reason)
        {:error, error_reason}
    end
  end

  def queue_process_wake_continuation(_root, _run, _event, _payload, _opts),
    do: {:error, :invalid_process_wake}

  def start_agent_work(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, mode} <- enum_value(attrs, "mode", @agent_modes, "work"),
         {:ok, targets} <- resolve_agent_work_targets(root, task, attrs),
         dispatch_plan = agent_work_dispatch_plan(task, targets, attrs, opts),
         {:ok, selected_targets} <- select_dispatched_agent_targets(task, targets, dispatch_plan) do
      execute_agent_work_targets(root, task, attrs, mode, selected_targets, dispatch_plan, opts)
    end
  end

  def start_agent_work_batch(params, opts \\ []) when is_map(params) do
    params = string_keys(params)

    case agent_work_request_items(params) do
      {:single, item} ->
        with {:ok, ref} <- task_ref_param(item) do
          start_agent_work(ref, item, opts)
        end

      {:batch, items} ->
        execute_agent_work_batch(items, opts)
    end
  end

  def continue_agent_work(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, previous_work} <- agent_work_to_continue(task, attrs),
         {:ok, mode} <- enum_value(attrs, "mode", @agent_modes, previous_work["mode"] || "work") do
      work_id = Clock.id("agent_work")
      now = Clock.iso_now()
      iteration = positive_integer(previous_work["iteration"], 1) + 1
      previous_run = agent_run_for_work(root, task["id"], previous_work)
      context_packet = task_memory_context_packet(root, task, attrs, opts)

      continuation_packet =
        build_continuation_packet(
          task,
          previous_work,
          previous_run,
          context_packet,
          Map.put(attrs, "depth", iteration),
          opts
        )

      attrs = Map.put(attrs, "continuation_packet", continuation_packet)

      agent_ids =
        normalize_string_list(
          Map.get(attrs, "agent_ids", previous_work["agent_ids"] || [@default_agent_id])
        )

      work =
        %{
          "id" => work_id,
          "agent_run_id" => Clock.id("agent_run"),
          "kind" => "continuation",
          "status" => "running",
          "mode" => mode,
          "iteration" => iteration,
          "continuation_of" => previous_work["id"],
          "resumed_from_run_id" => previous_work["run_id"],
          "message" => optional_text(attrs, "message"),
          "agent_ids" => agent_ids,
          "agent_id" => List.first(agent_ids) || previous_work["agent_id"],
          "assignee" => previous_work["assignee"],
          "dispatch_id" => previous_work["dispatch_id"],
          "dispatch_plan" => previous_work["dispatch_plan"],
          "task_graph_id" =>
            optional_text(attrs, "task_graph_id", optional_text(attrs, "graph_id")) ||
              previous_work["task_graph_id"],
          "task_graph_node_id" =>
            optional_text(attrs, "task_graph_node_id", optional_text(attrs, "node_id")) ||
              previous_work["task_graph_node_id"],
          "task_graph_node_key" =>
            optional_text(attrs, "task_graph_node_key", optional_text(attrs, "node_key")) ||
              previous_work["task_graph_node_key"],
          "source" => optional_text(attrs, "source"),
          "context_packet_id" => context_packet["packet_id"],
          "continuation_packet" => continuation_packet,
          "policy" => work_policy(attrs, opts, previous_work["policy"]),
          "created_at" => now,
          "started_at" => now
        }
        |> reject_empty()

      execute_agent_work(
        root,
        task,
        work,
        continuation_objective(task, previous_work, attrs),
        Keyword.put(opts, :resumed_from, previous_work["run_id"])
      )
    end
  end

  defp execute_agent_work(root, task, work, objective, opts) do
    now = Clock.iso_now()
    running_task_graph = mark_work_graph_node_running(root, work)
    {:ok, _queued_run} = AgentRuns.record_queued(root, task, Map.put(work, "status", "queued"))
    {:ok, _started_run} = AgentRuns.record_started(root, task, work)

    {:ok, _started_task} =
      update_task(root, task["id"], fn current ->
        current
        |> Map.put("status", "in_progress")
        |> Map.update("agent_work", [work], &(&1 ++ [work]))
        |> touch(now)
        |> append_activity("agent_work.started", %{
          "agent_work_id" => work["id"],
          "agent_id" => work["agent_id"],
          "dispatch_id" => work["dispatch_id"],
          "kind" => work["kind"],
          "mode" => work["mode"],
          "iteration" => work["iteration"],
          "resumed_from_run_id" => work["resumed_from_run_id"]
        })
      end)

    run_opts =
      opts
      |> Keyword.put(:agent, work_agent_label(task, work))
      |> Keyword.put(:task_id, task["id"])
      |> Keyword.put(:task_ref, task["ref"])

    case Runtime.run(objective, run_opts) do
      {:ok, %{run: run, artifact: artifact} = result} ->
        final_work =
          work
          |> Map.put("status", agent_work_status(run["status"]))
          |> Map.put("run_id", run["id"])
          |> Map.put("run_dir", run["run_dir"])
          |> maybe_put_artifact(artifact)
          |> Map.put("completed_at", Clock.iso_now())

        classification = AgentRunFailureClassifier.classify(run)
        policy = AgentRunPolicy.for_task(task, final_work)
        finished_task_graph = finish_work_graph_node(root, final_work, run, result)

        decision =
          continuation_decision(run, classification, policy, final_work)

        {:ok, _agent_run} =
          AgentRuns.record_completed(root, task, final_work, run, %{
            "verification_gate" => default_verification_gate(run),
            "output_summary" => summarize_output(Map.get(result, :output)),
            "classification" => classification,
            "policy" => policy,
            "continuation_decision" => decision
          })

        {:ok, final_task} =
          update_task(root, task["id"], fn current ->
            current
            |> Map.put("status", task_status_after_run(run["status"]))
            |> replace_agent_work(work["id"], final_work)
            |> touch()
            |> append_activity("agent_work.finished", %{
              "agent_work_id" => work["id"],
              "agent_id" => work["agent_id"],
              "dispatch_id" => work["dispatch_id"],
              "kind" => work["kind"],
              "iteration" => work["iteration"],
              "run_id" => run["id"],
              "run_status" => run["status"],
              "agent_work_status" => final_work["status"]
            })
          end)

        base_result =
          result
          |> Map.put(:task, enrich_task(root, final_task))
          |> Map.put(:agent_work, enrich_agent_work(final_work))
          |> Map.put(:continuation_decision, decision)
          |> Map.put(:task_graph, finished_task_graph || running_task_graph)
          |> Map.put(:task_graph_gate, graph_gate(finished_task_graph || running_task_graph))

        maybe_auto_continue(root, final_task, final_work, decision, base_result, opts)

      {:error, %{run: run, reason: reason}} ->
        final_work =
          work
          |> Map.put("status", agent_work_status(run["status"]))
          |> Map.put("run_id", run["id"])
          |> Map.put("run_dir", run["run_dir"])
          |> Map.put("failure_reason", inspect(reason))
          |> Map.put("completed_at", Clock.iso_now())

        classification = AgentRunFailureClassifier.classify(run, reason)
        policy = AgentRunPolicy.for_task(task, final_work)
        failed_task_graph = block_work_graph_node(root, final_work, run, reason)

        decision =
          continuation_decision(run, classification, policy, final_work)

        {:ok, _agent_run} =
          AgentRuns.record_completed(root, task, final_work, run, %{
            "verification_gate" => failure_verification_gate(run, reason),
            "error_message" => inspect(reason),
            "classification" => classification,
            "policy" => policy,
            "continuation_decision" => decision
          })

        {:ok, final_task} =
          update_task(root, task["id"], fn current ->
            current
            |> Map.put("status", "waiting")
            |> replace_agent_work(work["id"], final_work)
            |> touch()
            |> append_activity("agent_work.failed", %{
              "agent_work_id" => work["id"],
              "agent_id" => work["agent_id"],
              "dispatch_id" => work["dispatch_id"],
              "kind" => work["kind"],
              "iteration" => work["iteration"],
              "run_id" => run["id"],
              "run_status" => run["status"]
            })
          end)

        error_result = %{
          task: enrich_task(root, final_task),
          run: run,
          reason: reason,
          agent_work: enrich_agent_work(final_work),
          continuation_decision: decision,
          task_graph: failed_task_graph || running_task_graph,
          task_graph_gate: graph_gate(failed_task_graph || running_task_graph)
        }

        case decision["action"] do
          "continue" ->
            maybe_auto_continue(root, final_task, final_work, decision, error_result, opts)

          _action ->
            {:error, error_result}
        end

      {:error, reason} ->
        final_work =
          work
          |> Map.put("status", "failed")
          |> Map.put("failure_reason", inspect(reason))
          |> Map.put("completed_at", Clock.iso_now())

        failed_task_graph = block_work_graph_node(root, final_work, %{}, reason)

        {:ok, final_task} =
          update_task(root, task["id"], fn current ->
            current
            |> Map.put("status", "waiting")
            |> replace_agent_work(work["id"], final_work)
            |> touch()
            |> append_activity("agent_work.failed", %{
              "agent_work_id" => work["id"],
              "agent_id" => work["agent_id"],
              "dispatch_id" => work["dispatch_id"],
              "kind" => work["kind"],
              "iteration" => work["iteration"]
            })
          end)

        {:error,
         %{
           task: enrich_task(root, final_task),
           reason: reason,
           agent_work: enrich_agent_work(final_work),
           task_graph: failed_task_graph || running_task_graph,
           task_graph_gate: graph_gate(failed_task_graph || running_task_graph)
         }}
    end
  end

  def route_verification(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    attrs = string_keys(attrs)
    root = Paths.workspace_root(opts)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, checks} <- normalize_checks(Map.get(attrs, "checks", [])) do
      contract = evidence_contract_for_task(root, task, attrs)

      gateway =
        VerificationGateway.evaluate(%{
          "checks" => checks,
          "risk_flags" => Map.get(attrs, "risk_flags", []),
          "changed_files" => Map.get(attrs, "changed_files", []),
          "evidence" => Map.get(attrs, "evidence", []),
          "ui_walkthrough_status" =>
            optional_text(attrs, "ui_walkthrough_status", "not_applicable"),
          "api_verification_status" =>
            optional_text(attrs, "api_verification_status", "not_applicable"),
          "graphql_verification_status" =>
            optional_text(attrs, "graphql_verification_status", "not_applicable"),
          "evidence_contract" => contract
        })

      route = VerificationGateway.route(gateway)
      task_status = verification_task_status(route)

      report =
        %{
          "schema_version" => "holtworks_verification_report/v1",
          "id" => Clock.id("verification"),
          "task_id" => task["id"],
          "task_ref" => task["ref"],
          "summary" => optional_text(attrs, "summary", ""),
          "checks" => checks,
          "risk_flags" => normalize_string_list(Map.get(attrs, "risk_flags", [])),
          "changed_files" => normalize_string_list(Map.get(attrs, "changed_files", [])),
          "evidence" => normalize_string_list(Map.get(attrs, "evidence", [])),
          "ui_walkthrough_status" =>
            optional_text(attrs, "ui_walkthrough_status", "not_applicable"),
          "api_verification_status" =>
            optional_text(attrs, "api_verification_status", "not_applicable"),
          "graphql_verification_status" =>
            optional_text(attrs, "graphql_verification_status", "not_applicable"),
          "decision" => task_status,
          "route" => route,
          "gateway" => gateway,
          "evidence_contract" => contract,
          "evidence_evaluation" => gateway["evidence_evaluation"],
          "metadata" => normalize_metadata(Map.get(attrs, "metadata", %{})),
          "created_at" => Clock.iso_now()
        }
        |> reject_empty()

      {:ok, spec} =
        save_spec(
          ref_or_id,
          %{
            "kind" => "verification_report",
            "title" => "Verification " <> task["ref"],
            "content" => verification_markdown(task, report)
          },
          opts
        )

      {:ok, updated_task} =
        update_task(root, task["id"], fn current ->
          current
          |> Map.put("status", task_status)
          |> maybe_append_verification_comment(report, spec, attrs)
          |> touch()
          |> append_activity("task.verification_routed", %{
            "report_id" => report["id"],
            "spec_id" => spec["id"],
            "decision" => task_status,
            "can_finish" => route["can_finish"]
          })
        end)

      {:ok, _agent_run} = AgentRuns.record_verification(root, updated_task, report)
      {:ok, task_graph} = TaskGraphs.record_verification(root, updated_task, report, spec, attrs)

      {:ok,
       %{
         task: enrich_task(root, updated_task),
         report: report,
         spec: spec,
         gateway: gateway,
         task_graph: task_graph,
         task_graph_gate: graph_gate(task_graph)
       }}
    end
  end

  def tasks_path(root), do: Path.join(Paths.tasks_dir(root), "tasks.json")
  def counter_path(root), do: Path.join(Paths.tasks_dir(root), "counter.json")
  def specs_index_path(root), do: Path.join(Paths.tasks_dir(root), "specs.json")
  def agents_path(root), do: Agents.path(root)
  def agent_events_path(root), do: Agents.events_path(root)
  def agent_runs_path(root), do: AgentRuns.path(root)
  def agent_run_events_path(root), do: AgentRuns.events_path(root)
  def task_graphs_path(root), do: TaskGraphs.path(root)
  def task_graph_events_path(root), do: TaskGraphs.events_path(root)

  def verifier_calibrations_path(root),
    do: Path.join(Paths.tasks_dir(root), "verifier_calibrations.json")

  defp ensure_store(root) do
    Paths.ensure_workspace(root)
    File.mkdir_p!(Paths.tasks_dir(root))
    File.mkdir_p!(Paths.task_specs_dir(root))
    unless File.exists?(tasks_path(root)), do: JSON.write(tasks_path(root), [])
    unless File.exists?(specs_index_path(root)), do: JSON.write(specs_index_path(root), [])
    Agents.ensure_store(root)
    AgentRuns.ensure_store(root)
    TaskGraphs.ensure_store(root)
    TaskMemory.ensure_store(root)

    unless File.exists?(verifier_calibrations_path(root)),
      do: JSON.write(verifier_calibrations_path(root), [])

    unless File.exists?(counter_path(root)),
      do: JSON.write(counter_path(root), %{"next_number" => 1})

    :ok
  end

  defp load_tasks(root), do: JSON.read(tasks_path(root), [])
  defp load_specs(root), do: JSON.read(specs_index_path(root), [])

  defp enrich_task(root, task) do
    runs = AgentRuns.list_for_task(task["id"], workspace: root)

    task
    |> Map.update("assignees", [], &Agents.enrich_assignees(root, &1))
    |> Map.update("agent_work", [], fn work_items ->
      Enum.map(work_items, &enrich_agent_work(&1, runs))
    end)
  end

  defp enrich_agent_work(work), do: AgentWorkLiveness.enrich(work)

  defp enrich_agent_work(work, runs) do
    run =
      Enum.find(runs, fn candidate ->
        candidate["id"] == work["agent_run_id"] or candidate["work_id"] == work["id"]
      end)

    work
    |> maybe_put_agent_run_summary(run)
    |> AgentWorkLiveness.enrich()
  end

  defp maybe_put_agent_run_summary(work, nil), do: work

  defp maybe_put_agent_run_summary(work, run) do
    Map.put(work, "agent_run", %{
      "id" => run["id"],
      "status" => run["status"],
      "lifecycle_state" => run["lifecycle_state"],
      "runtime_status" => run["runtime_status"],
      "objective_status" => run["objective_status"],
      "agent_id" => run["agent_id"],
      "dispatch_id" => run["dispatch_id"],
      "source" => run["source"],
      "previous_run_id" => run["previous_run_id"]
    })
  end

  defp graph_gate(nil), do: nil
  defp graph_gate(graph), do: graph["mission_control"]

  defp agent_run_events_for_task(root, task) do
    root
    |> AgentRuns.event_log()
    |> Enum.filter(fn event ->
      event["task_id"] == task["id"] or event["task_ref"] == task["ref"]
    end)
  end

  defp latest_verification_gate(agent_runs) do
    agent_runs
    |> Enum.reverse()
    |> Enum.find_value(fn run ->
      case run["verification_gate"] do
        gate when is_map(gate) and gate != %{} -> gate
        _missing -> nil
      end
    end)
  end

  defp action_contract_for_child(ref_or_id, attrs, opts) do
    case optional_text(attrs, "tool_name", optional_text(attrs, "name")) do
      tool_name when tool_name in [nil, ""] ->
        {:ok, %{}}

      _tool_name ->
        action_contract(ref_or_id, attrs, opts)
    end
  end

  defp child_agent_context(task, attrs) do
    %{
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "parent_task_id" => task["parent_id"],
      "agent_id" => optional_text(attrs, "agent_id", optional_text(attrs, "agent")),
      "run_id" => optional_text(attrs, "run_id", optional_text(attrs, "agent_run_id"))
    }
    |> reject_empty()
  end

  defp evidence_contract_for_task(root, task, attrs) do
    specs =
      root
      |> load_specs()
      |> Enum.filter(&(&1["task_id"] == task["id"]))
      |> Enum.filter(
        &(&1["kind"] in ["workflow_contract", "validation_contract", "outcome_contract"])
      )
      |> Enum.map(&maybe_include_spec_content(&1, root, true, 50_000))

    EvidenceContract.build_for_task(task, specs, attrs)
  end

  defp verifier_route_graph(root, task, attrs) do
    case optional_text(attrs, "graph_id", optional_text(attrs, "task_graph_id")) do
      graph_id when graph_id not in [nil, ""] ->
        TaskGraphs.get(root, graph_id)

      _missing ->
        root
        |> TaskGraphs.list_for_task(task["id"])
        |> List.last()
        |> case do
          nil -> {:error, :task_graph_not_found}
          graph -> {:ok, graph}
        end
    end
  end

  defp maybe_plan_graph(root, task, attrs) do
    case optional_text(attrs, "graph_id", optional_text(attrs, "task_graph_id")) do
      graph_id when graph_id not in [nil, ""] ->
        TaskGraphs.get(root, graph_id)

      _missing ->
        {:ok, TaskGraphs.list_for_task(root, task["id"]) |> List.last()}
    end
  end

  defp calibration_assignment(ref_or_id, attrs, opts) do
    case Map.get(attrs, "verifier_assignment") || Map.get(attrs, "assignment") do
      assignment when is_map(assignment) ->
        {:ok, string_keys(assignment)}

      _missing ->
        verifier_assignment(ref_or_id, attrs, opts)
    end
  end

  defp verifier_available_agents(root, task, attrs) do
    source =
      case Map.get(attrs, "available_agents") do
        agents when is_list(agents) and agents != [] -> agents
        _missing -> task["assignees"] || []
      end

    source
    |> normalize_assignees()
    |> then(&Agents.dispatchable_assignees(root, &1))
    |> Enum.filter(&agent_assignee?/1)
  end

  defp load_verifier_calibrations(root) do
    JSON.read(verifier_calibrations_path(root), [])
  end

  defp persist_verifier_calibration(calibration, root) do
    ensure_store(root)

    records =
      root
      |> load_verifier_calibrations()
      |> Enum.reject(&(&1["calibration_id"] == calibration["calibration_id"]))
      |> Kernel.++([calibration])

    JSON.write(verifier_calibrations_path(root), records)
    calibration
  end

  defp verifier_quality_records(root) do
    root
    |> load_verifier_calibrations()
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&(&1["verifier_agent_id"] in [nil, ""]))
    |> Enum.group_by(& &1["verifier_agent_id"])
    |> Enum.map(fn {agent_id, records} ->
      matched = Enum.count(records, &(&1["later_outcome"] == "matched"))
      missed = Enum.count(records, &(&1["later_outcome"] == "missed_failure"))
      false_blocks = Enum.count(records, &(&1["later_outcome"] == "false_block"))
      total = max(length(records), 1)

      %{
        "verifier_agent_id" => agent_id,
        "agent_id" => agent_id,
        "accuracy" => Float.round(matched / total, 2),
        "matched_count" => matched,
        "missed_failure_count" => missed,
        "false_block_count" => false_blocks,
        "sample_count" => length(records)
      }
    end)
  end

  defp route_task_tool_session(ref_or_id, attrs, opts) do
    case Map.get(attrs, "task_tool_session") || Map.get(attrs, "session") do
      session when is_map(session) ->
        {:ok, TaskToolSession.build(session)}

      _missing ->
        task_tool_session(ref_or_id, attrs, opts)
    end
  end

  defp action_runtime_attrs(ref_or_id, attrs, opts) do
    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, route} <- route_task_tool(ref_or_id, attrs, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      gate =
        PlanGate.evaluate(%{
          "task_tool_route" => route,
          "action_contract" => route["action_contract"],
          "plan_contract" => plan
        })

      preflight =
        ActionPreflight.evaluate(
          attrs
          |> Map.put("task_tool_route", route)
          |> Map.put("action_contract", route["action_contract"])
          |> Map.put("plan_contract", plan)
          |> Map.put("plan_gate", gate)
        )

      {:ok,
       attrs
       |> Map.put("task", task)
       |> Map.put("context", action_runtime_context(task, attrs))
       |> Map.put("task_tool_route", route)
       |> Map.put("action_contract", route["action_contract"])
       |> Map.put("plan_contract", plan)
       |> Map.put("plan_gate", gate)
       |> Map.put("action_preflight", preflight)}
    end
  end

  defp evidence_envelope(ref_or_id, attrs, opts) do
    case Map.get(attrs, "action_runtime_envelope") || Map.get(attrs, "envelope") do
      envelope when is_map(envelope) ->
        {:ok, string_keys(envelope)}

      _missing ->
        with {:ok, proposed} <- action_runtime_envelope(ref_or_id, attrs, opts) do
          if completion_attrs?(attrs) do
            complete_attrs = normalize_evidence_completion_attrs(attrs)
            complete_action_runtime_envelope(proposed, complete_attrs)
          else
            {:ok, proposed}
          end
        end
    end
  end

  defp completion_attrs?(attrs) do
    Enum.any?(
      ~w(result status result_status execution_observation observed_changes observed_state_changes),
      &Map.has_key?(attrs, &1)
    )
  end

  defp normalize_evidence_completion_attrs(attrs) do
    attrs
    |> maybe_put_result_from_status()
  end

  defp maybe_put_result_from_status(%{"result" => _result} = attrs), do: attrs

  defp maybe_put_result_from_status(attrs) do
    status = Map.get(attrs, "result_status") || Map.get(attrs, "status")

    if status in [nil, ""] do
      attrs
    else
      Map.put(attrs, "result", %{
        "status" => status,
        "preview" => Map.get(attrs, "result_preview")
      })
    end
  end

  defp maybe_put_evidence_approval_request(attrs, nil), do: attrs

  defp maybe_put_evidence_approval_request(attrs, request) do
    Map.put(attrs, "approval_request", request)
  end

  defp maybe_record_approval_memory(_root, %{"approval_request_id" => nil}), do: :ok
  defp maybe_record_approval_memory(_root, %{"status" => "not_required"}), do: :ok

  defp maybe_record_approval_memory(root, request) when is_map(request) do
    case get(request["task_id"] || request["task_ref"], workspace: root) do
      {:ok, task} ->
        TaskMemory.record_artifact(root, task, %{
          "kind" => "human_approval_request",
          "title" => "Approval request #{request["approval_request_id"]}",
          "content" => Jason.encode!(request, pretty: true),
          "source" => "action_approval_request",
          "metadata" => %{
            "approval_request_id" => request["approval_request_id"],
            "tool_name" => request["tool_name"],
            "status" => request["status"]
          }
        })

        :ok

      _error ->
        :ok
    end
  end

  defp maybe_record_approval_memory(_root, _request), do: :ok

  defp maybe_record_ledger_memory(root, task, ledger) do
    TaskMemory.record_artifact(root, task, %{
      "kind" => "evidence_ledger",
      "title" => "Evidence ledger #{ledger["ledger_id"]}",
      "content" => Jason.encode!(ledger, pretty: true),
      "source" => "action_evidence_ledger",
      "metadata" => %{
        "ledger_id" => ledger["ledger_id"],
        "tool_name" => ledger["source_tool_name"]
      }
    })

    :ok
  end

  defp action_approval_requests_path(root) do
    Path.join(Paths.tasks_dir(root), "human_approval_requests.json")
  end

  defp action_evidence_ledgers_path(root) do
    Path.join(Paths.tasks_dir(root), "evidence_ledgers.json")
  end

  defp load_action_approval_requests(root) do
    JSON.read(action_approval_requests_path(root), [])
  end

  defp load_action_evidence_ledgers(root) do
    JSON.read(action_evidence_ledgers_path(root), [])
  end

  defp persist_action_approval_request(root, request) do
    ensure_store(root)

    records =
      root
      |> load_action_approval_requests()
      |> Enum.reject(&(&1["approval_request_id"] == request["approval_request_id"]))
      |> Kernel.++([request])

    JSON.write(action_approval_requests_path(root), records)
    request
  end

  defp persist_action_approval_resolution(root, request, resolution) when is_map(resolution) do
    ensure_store(root)

    updated =
      request
      |> Map.put("status", resolution["status"])
      |> Map.put("resolution", resolution)
      |> Map.put("resolved_at", resolution["resolved_at"])
      |> reject_empty()

    records =
      root
      |> load_action_approval_requests()
      |> Enum.reject(&(&1["approval_request_id"] == request["approval_request_id"]))
      |> Kernel.++([updated])

    JSON.write(action_approval_requests_path(root), records)
    updated
  end

  defp find_action_approval_request(root, request_id) do
    root
    |> load_action_approval_requests()
    |> Enum.find(&(&1["approval_request_id"] == request_id))
  end

  defp persist_action_evidence_ledger(root, ledger) do
    ensure_store(root)

    records =
      root
      |> load_action_evidence_ledgers()
      |> Enum.reject(&(&1["ledger_id"] == ledger["ledger_id"]))
      |> Kernel.++([ledger])

    JSON.write(action_evidence_ledgers_path(root), records)
    ledger
  end

  defp envelope_task_ref(envelope) do
    get_in(envelope, ["action_contract", "target_refs", "task_ref"]) ||
      get_in(envelope, ["state_snapshot", "task_state", "task_ref"])
  end

  defp envelope_task_id(envelope) do
    get_in(envelope, ["action_contract", "target_refs", "task_id"]) ||
      get_in(envelope, ["state_snapshot", "task_state", "task_id"])
  end

  defp capability_attrs(ref_or_id, attrs, opts) do
    root = Paths.workspace_root(opts)
    attrs = string_keys(attrs)

    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, session} <- route_task_tool_session(ref_or_id, attrs, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      {:ok,
       attrs
       |> Map.put("task", task)
       |> Map.put("workspace", root)
       |> Map.put("task_tool_session", session)
       |> Map.put("plan_contract", plan)
       |> Map.put("evidence_contract", evidence_contract_for_task(root, task, attrs))
       |> Map.put("available_agents", available_capability_agents(task, attrs))}
    end
  end

  defp available_capability_agents(task, attrs) do
    attrs = string_keys(attrs || %{})

    case Map.get(attrs, "available_agents") do
      agents when is_list(agents) and agents != [] ->
        agents

      agents when is_binary(agents) and agents != "" ->
        normalize_string_list(agents)

      _missing ->
        task["assignees"] || []
    end
  end

  defp action_runtime_context(task, attrs) do
    %{
      "autonomous" => Map.get(attrs, "autonomous", true),
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "parent_task_id" => task["parent_id"],
      "agent_id" => optional_text(attrs, "agent_id", optional_text(attrs, "agent", "default")),
      "agent_ref" => optional_text(attrs, "agent_ref"),
      "run_id" => optional_text(attrs, "run_id", optional_text(attrs, "agent_run_id")),
      "work_role" => optional_text(attrs, "work_role"),
      "approval_status" => optional_text(attrs, "approval_status"),
      "approval_already_granted" => Map.get(attrs, "approval_already_granted"),
      "policy_approval_granted" => Map.get(attrs, "policy_approval_granted"),
      "stale_state_detected" => Map.get(attrs, "stale_state_detected"),
      "resource_stale" => Map.get(attrs, "resource_stale")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp task_memory_context_attrs(root, task, attrs, opts) do
    content_limit =
      positive_integer(option(opts, :content_limit) || attrs["content_limit"], 1_600)

    specs =
      root
      |> load_specs()
      |> Enum.filter(&(&1["task_id"] == task["id"]))
      |> Enum.filter(&(&1["kind"] in @runtime_spec_kinds))
      |> Enum.map(&maybe_include_spec_content(&1, root, true, content_limit))

    attrs
    |> Map.put("specs", specs)
    |> Map.put("agent_runs", AgentRuns.list_for_task(task["id"], workspace: root))
    |> Map.put_new("policy", task["agent_policy"] || %{})
  end

  defp task_memory_context_packet(root, task, attrs, opts) do
    case TaskMemory.context_packet(root, task, task_memory_context_attrs(root, task, attrs, opts)) do
      {:ok, packet} ->
        packet

      {:error, _reason} ->
        %{
          "schema_version" => "holtworks_task_memory_context_packet/v1",
          "packet_id" => Clock.id("task_memory_packet"),
          "task_id" => task["id"],
          "task_ref" => task["ref"],
          "memory_state" => %{"durable_truth" => "file_backed_task_memory_unavailable"}
        }
    end
  end

  defp agent_run_for_work(root, task_id, work) do
    task_id
    |> AgentRuns.list_for_task(workspace: root)
    |> Enum.find(fn run ->
      run["id"] == work["agent_run_id"] or run["work_id"] == work["id"] or
        run["run_id"] == work["run_id"]
    end)
  end

  defp build_continuation_packet(task, previous_work, previous_run, context_packet, attrs, opts) do
    ContinuationPacket.build(%{
      "task" => task,
      "agent_work" => previous_work,
      "agent_run" => previous_run || %{},
      "context_packet" => context_packet,
      "depth" => attrs["depth"] || attrs["continuation_depth"],
      "agent_id" =>
        optional_text(attrs, "agent_id") || List.first(normalize_string_list(attrs["agent_ids"])) ||
          previous_work["agent_id"],
      "source" =>
        optional_text(attrs, "source", option(opts, :source) || "task_agent_continuation"),
      "resources" => %{
        "workspace_required" => true,
        "task_memory_artifact_refs" => context_packet["artifact_refs"] || []
      }
    })
  end

  defp mark_work_graph_node_running(root, work) do
    case work_graph_node_context(work) do
      nil ->
        nil

      {graph_id, node_ref} ->
        case TaskGraphs.mark_node_running(root, graph_id, node_ref, %{
               "agent_id" => work["agent_id"],
               "agent_work_id" => work["id"],
               "agent_run_id" => work["agent_run_id"]
             }) do
          {:ok, graph} -> graph
          {:error, _reason} -> nil
        end
    end
  end

  defp finish_work_graph_node(root, work, run, result) do
    case work_graph_node_context(work) do
      nil ->
        nil

      {graph_id, node_ref} ->
        case TaskGraphs.complete_node(root, graph_id, node_ref, %{
               "status" => work_graph_completion_status(run),
               "agent_id" => work["agent_id"],
               "agent_work_id" => work["id"],
               "agent_run_id" => work["agent_run_id"],
               "run_id" => run["id"],
               "summary" => summarize_output(Map.get(result, :output)),
               "metadata" => %{
                 "runtime_status" => run["status"],
                 "run_dir" => run["run_dir"]
               }
             }) do
          {:ok, graph} -> graph
          {:error, _reason} -> nil
        end
    end
  end

  defp block_work_graph_node(root, work, run, reason) do
    case work_graph_node_context(work) do
      nil ->
        nil

      {graph_id, node_ref} ->
        case TaskGraphs.block_node(root, graph_id, node_ref, %{
               "code" => work["blocker_code"] || "agent_work_failed",
               "message" => inspect(reason),
               "agent_id" => work["agent_id"],
               "agent_work_id" => work["id"],
               "agent_run_id" => work["agent_run_id"],
               "run_id" => run["id"],
               "metadata" => %{
                 "runtime_status" => run["status"],
                 "run_dir" => run["run_dir"]
               }
             }) do
          {:ok, graph} -> graph
          {:error, _reason} -> nil
        end
    end
  end

  defp work_graph_node_context(work) do
    graph_id = work["task_graph_id"]
    node_ref = work["task_graph_node_id"] || work["task_graph_node_key"] || "work"

    if graph_id in [nil, ""] do
      nil
    else
      {graph_id, node_ref}
    end
  end

  defp work_graph_completion_status(%{"status" => "completed"}), do: "done"
  defp work_graph_completion_status(%{"status" => "blocked"}), do: "blocked"
  defp work_graph_completion_status(_run), do: "failed"

  defp continuation_decision(run, classification, policy, work) do
    AgentRunDecision.decide(%{
      "run_status" => run["status"],
      "classification" => classification,
      "policy" => policy,
      "continuation_count" => positive_integer(work["iteration"], 1) - 1
    })
  end

  defp maybe_auto_continue(root, task, work, %{"action" => "continue"} = decision, result, opts) do
    {:ok, _requested_task} =
      update_task(root, task["id"], fn current ->
        append_activity(current, "agent_continuation_requested", %{
          "agent_work_id" => work["id"],
          "run_id" => work["run_id"],
          "continuation_depth" => decision["depth"],
          "reason" => decision["reason"],
          "source" => "task_agent_continuation"
        })
      end)

    attrs =
      %{
        "message" => auto_continuation_message(work, decision),
        "policy" => work["policy"],
        "agent_ids" => work["agent_ids"]
      }
      |> reject_empty()

    case continue_agent_work(task["id"], attrs, opts) do
      {:ok, continuation} ->
        {:ok,
         result
         |> Map.put(:task, continuation[:task])
         |> Map.put(:auto_continuation, continuation)}

      {:error, continuation_error} ->
        {:ok, Map.put(result, :auto_continuation_error, continuation_error)}
    end
  end

  defp maybe_auto_continue(root, task, work, %{"action" => "suppress"} = decision, result, _opts) do
    {:ok, updated_task} =
      update_task(root, task["id"], fn current ->
        append_activity(current, "agent_continuation_suppressed", %{
          "agent_work_id" => work["id"],
          "run_id" => work["run_id"],
          "reason" => decision["reason"],
          "failure_class" => decision["failure_class"],
          "blocker_code" => decision["blocker_code"]
        })
      end)

    {:ok, Map.put(result, :task, enrich_task(root, updated_task))}
  end

  defp maybe_auto_continue(_root, _task, _work, _decision, result, _opts), do: {:ok, result}

  defp evaluate_watchdog_run(root, run, opts) do
    now = option(opts, :now) || Clock.now()
    snapshot = AgentRuns.watchdog_snapshot(root, run)

    cond do
      objective_satisfied?(snapshot) ->
        observe_watchdog_run(root, run, "objective_satisfied", snapshot, opts)

      recent_watchdog_recovery?(run, now) ->
        observe_watchdog_run(root, run, "recovery_cooldown", snapshot, opts)

      watchdog_needs_recovery?(snapshot) ->
        recover_watchdog_run(root, run, watchdog_recovery_reason(snapshot), snapshot, opts)

      legitimate_watchdog_wait?(snapshot) ->
        observe_watchdog_run(root, run, "legitimate_wait", snapshot, opts)

      stale_watchdog_run?(run, now, opts) ->
        recover_watchdog_run(root, run, stale_watchdog_reason(run), snapshot, opts)

      true ->
        observe_watchdog_run(root, run, "active", snapshot, opts)
    end
  end

  defp observe_watchdog_run(root, run, reason, snapshot, opts) do
    next_wake_at = watchdog_next_wake_at(reason, opts)

    {:ok, _record} =
      AgentRuns.record_watchdog_observation(root, run, reason, snapshot,
        next_wake_at: next_wake_at
      )

    %{
      "agent_run_id" => run["id"],
      "task_ref" => run["task_ref"],
      "agent_id" => run["agent_id"],
      "action" => "observed",
      "reason" => reason
    }
    |> reject_empty()
  end

  defp recover_watchdog_run(root, run, reason, snapshot, opts) do
    with {:ok, task} <- get(run["task_id"], workspace: root),
         :ok <- ensure_latest_watchdog_run(root, run),
         :ok <- ensure_watchdog_task_open(task),
         :ok <- ensure_no_other_active_agent_work(task, run),
         packet = watchdog_recovery_packet(task, run, reason, snapshot),
         {:ok, marked_task} <- mark_task_watchdog_recovery(root, task, run, packet, reason),
         {:ok, _record} <-
           AgentRuns.mark_watchdog_recovery_queued(
             root,
             run,
             packet,
             reason,
             next_wake_at: watchdog_next_wake_at("recovery_queued", opts)
           ),
         {:ok, recovery_result} <- start_watchdog_recovery_work(marked_task, run, packet, opts) do
      %{
        "agent_run_id" => run["id"],
        "task_ref" => task["ref"],
        "agent_id" => run["agent_id"],
        "action" => "recovery_queued",
        "reason" => reason,
        "recovery_agent_work_id" => recovery_result[:agent_work]["id"],
        "recovery_run_id" => recovery_result[:run]["id"]
      }
      |> reject_empty()
    else
      {:error, error_reason} ->
        packet = watchdog_recovery_packet(%{}, run, reason, snapshot)
        {:ok, _record} = AgentRuns.mark_watchdog_recovery_failed(root, run, packet, error_reason)

        %{
          "agent_run_id" => run["id"],
          "task_ref" => run["task_ref"],
          "agent_id" => run["agent_id"],
          "action" => "recovery_failed",
          "reason" => inspect(error_reason)
        }
        |> reject_empty()
    end
  end

  defp mark_task_process_wake(root, task, run, packet, reason) do
    update_task(root, task["id"], fn current ->
      current
      |> Map.update("agent_work", [], fn work_items ->
        Enum.map(work_items, fn work ->
          if work["id"] == run["work_id"] do
            work
            |> Map.put("process_wake_status", "wake_queued")
            |> Map.put("process_wake_reason", reason)
            |> Map.put("process_wake_packet", packet)
            |> Map.put("process_wake_queued_at", Clock.iso_now())
          else
            work
          end
        end)
      end)
      |> Map.put("status", "in_progress")
      |> touch()
      |> append_activity("agent_process_wake_queued", %{
        "agent_run_id" => run["id"],
        "agent_work_id" => run["work_id"],
        "agent_id" => run["agent_id"],
        "reason" => reason,
        "source" => @process_wake_source,
        "process_event_id" => packet["process_event_id"]
      })
    end)
  end

  defp maybe_start_process_wake_continuation(task, run, packet, _wake_event, opts) do
    if option(opts, :auto_continue) == true do
      attrs =
        %{
          "message" => process_wake_message(task, packet),
          "source" => @process_wake_source,
          "request_id" => packet["process_event_id"],
          "agent_ids" => [run["agent_id"]],
          "previous_agent_work_id" => run["work_id"],
          "previous_agent_run_id" => run["id"],
          "policy" => run["policy"]
        }
        |> reject_empty()

      continue_opts =
        opts
        |> Keyword.put(:source, @process_wake_source)
        |> Keyword.put(:policy_source, @process_wake_source)

      case continue_agent_work(task["id"], attrs, continue_opts) do
        {:ok, continuation} ->
          {:ok,
           %{
             "action" => "wake_continuation_started",
             "continuation_agent_work_id" => continuation[:agent_work]["id"],
             "continuation_run_id" => continuation[:run]["id"]
           }}

        {:error, continuation_error} ->
          {:error, continuation_error}
      end
    else
      {:ok, %{"action" => "wake_queued"}}
    end
  end

  defp process_wake_packet(task, run, event, payload, reason) do
    %{
      "schema_version" => "holtworks_agent_process_wake/v1",
      "source" => @process_wake_source,
      "reason" => reason,
      "previous_agent_run_id" => run["id"],
      "previous_runtime_run_id" => run["run_id"],
      "previous_agent_work_id" => run["work_id"],
      "task_id" => run["task_id"] || task["id"],
      "task_ref" => run["task_ref"] || task["ref"],
      "task_title" => run["task_title"] || task["title"],
      "task_status" => task["status"],
      "agent_id" => run["agent_id"],
      "process_event_id" => event["id"],
      "process_event_kind" => event["type"] || event["kind"],
      "process" => payload,
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp process_wake_reason(%{"type" => "process.missing"}, _payload), do: "process_missing"
  defp process_wake_reason(%{"kind" => "process.missing"}, _payload), do: "process_missing"
  defp process_wake_reason(_event, %{"status" => "missing"}), do: "process_missing"
  defp process_wake_reason(_event, _payload), do: "process_exited"

  defp process_wake_message(task, packet) do
    packet_json = Jason.encode!(packet, pretty: true)

    """
    Holt observed a previously awaited process terminal event. Continue the same task from this structured process wake packet.

    Task ID: #{task["id"]}
    Task: #{task["ref"]}
    Title: #{task["title"]}
    Status: #{task["status"]}

    Process wake packet:
    #{packet_json}

    Use the process status, exit code, and saved task artifacts as source-of-truth. Continue from the next verified step and route verification before finishing.
    """
    |> String.trim()
  end

  defp start_watchdog_recovery_work(task, run, packet, opts) do
    attrs =
      %{
        "message" => watchdog_recovery_message(task, packet),
        "source" => @watchdog_recovery_source,
        "request_id" => run["id"],
        "agent_ids" => [run["agent_id"]],
        "previous_agent_work_id" => run["work_id"],
        "previous_agent_run_id" => run["id"],
        "policy" => run["policy"]
      }
      |> reject_empty()

    recovery_opts =
      opts
      |> Keyword.put(:source, @watchdog_recovery_source)
      |> Keyword.put(:policy_source, @watchdog_recovery_source)

    if run["run_id"] in [nil, ""] do
      start_agent_work(task["id"], attrs, recovery_opts)
    else
      continue_agent_work(task["id"], attrs, recovery_opts)
    end
  end

  defp mark_task_watchdog_recovery(root, task, run, packet, reason) do
    update_task(root, task["id"], fn current ->
      current
      |> Map.update("agent_work", [], fn work_items ->
        Enum.map(work_items, fn work ->
          if work["id"] == run["work_id"] do
            work
            |> Map.put("status", "recovery_queued")
            |> Map.put("watchdog_status", "recovery_queued")
            |> Map.put("watchdog_recovery_reason", reason)
            |> Map.put("watchdog_recovery_packet", packet)
            |> Map.put("watchdog_recovery_queued_at", Clock.iso_now())
          else
            work
          end
        end)
      end)
      |> Map.put("status", "in_progress")
      |> touch()
      |> append_activity("agent_watchdog_recovery_queued", %{
        "agent_run_id" => run["id"],
        "agent_work_id" => run["work_id"],
        "agent_id" => run["agent_id"],
        "reason" => reason,
        "source" => @watchdog_recovery_source
      })
    end)
  end

  defp watchdog_recovery_packet(task, run, reason, snapshot) do
    %{
      "schema_version" => "holtworks_agent_run_watchdog_recovery/v1",
      "source" => @watchdog_recovery_source,
      "reason" => reason,
      "previous_agent_run_id" => run["id"],
      "previous_runtime_run_id" => run["run_id"],
      "previous_agent_work_id" => run["work_id"],
      "task_id" => run["task_id"] || task["id"],
      "task_ref" => run["task_ref"] || task["ref"],
      "task_title" => run["task_title"] || task["title"],
      "task_status" => task["status"],
      "agent_id" => run["agent_id"],
      "objective_status" => snapshot["objective_status"],
      "lifecycle_state" => snapshot["lifecycle_state"],
      "runtime_status" => snapshot["runtime_status"],
      "last_event_at" => snapshot["last_event_at"],
      "last_effective_work_at" => snapshot["last_effective_work_at"],
      "heartbeat_at" => snapshot["heartbeat_at"],
      "snapshot" => snapshot,
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp watchdog_recovery_message(task, packet) do
    packet_json = Jason.encode!(packet, pretty: true)

    """
    Holt detected that the previous agent run is no longer making effective progress. Continue the same task from this structured watchdog recovery packet.

    Task ID: #{task["id"]}
    Task: #{task["ref"]}
    Title: #{task["title"]}
    Status: #{task["status"]}

    Watchdog recovery packet:
    #{packet_json}

    Continue from the next verified step. Use the packet's objective status, latest events, and saved artifacts as source-of-truth. Verify with task artifacts and route verification before finishing.
    """
    |> String.trim()
  end

  defp watchdog_candidate?(run) do
    run["lifecycle_state"] not in ["completed", "canceled"] and
      run["objective_status"] not in ["satisfied", "met"]
  end

  defp objective_satisfied?(%{"objective_status" => status}) when status in ["satisfied", "met"],
    do: true

  defp objective_satisfied?(%{"lifecycle_state" => "completed"}), do: true
  defp objective_satisfied?(_snapshot), do: false

  defp watchdog_needs_recovery?(%{"lifecycle_state" => "needs_continuation"}), do: true

  defp watchdog_needs_recovery?(%{
         "lifecycle_state" => "blocked",
         "failure_retryable" => true
       }),
       do: true

  defp watchdog_needs_recovery?(_snapshot), do: false

  defp watchdog_recovery_reason(%{"lifecycle_state" => "needs_continuation"}),
    do: "needs_continuation"

  defp watchdog_recovery_reason(%{"lifecycle_state" => "blocked"}), do: "retryable_blocked_run"
  defp watchdog_recovery_reason(_snapshot), do: "stale_run"

  defp legitimate_watchdog_wait?(%{"lifecycle_state" => "awaiting_verification"}), do: true

  defp legitimate_watchdog_wait?(%{
         "lifecycle_state" => "blocked",
         "failure_retryable" => retryable
       })
       when retryable in [false, "false"],
       do: true

  defp legitimate_watchdog_wait?(_snapshot), do: false

  defp stale_watchdog_run?(run, now, opts) do
    run["lifecycle_state"] in ["queued", "running"] and
      elapsed_seconds?(watchdog_activity_anchor(run), now, watchdog_stale_after_seconds(opts))
  end

  defp stale_watchdog_reason(%{"lifecycle_state" => "queued"}), do: "queued_stale"
  defp stale_watchdog_reason(_run), do: "stale_run"

  defp watchdog_activity_anchor(run) do
    [
      run["last_effective_work_at"],
      run["heartbeat_at"],
      run["last_event_at"],
      run["started_at"],
      run["queued_at"],
      run["inserted_at"]
    ]
    |> Enum.map(&parse_datetime/1)
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp recent_watchdog_recovery?(run, now) do
    case parse_datetime(run["next_wake_at"]) do
      %DateTime{} = next_wake_at -> DateTime.compare(next_wake_at, now) == :gt
      _value -> false
    end
  end

  defp watchdog_next_wake_at("active", opts),
    do: seconds_from_now(watchdog_stale_after_seconds(opts))

  defp watchdog_next_wake_at("recovery_queued", opts),
    do: seconds_from_now(watchdog_recovery_cooldown_seconds(opts))

  defp watchdog_next_wake_at("recovery_cooldown", opts),
    do: seconds_from_now(watchdog_recovery_cooldown_seconds(opts))

  defp watchdog_next_wake_at(_reason, _opts), do: nil

  defp ensure_latest_watchdog_run(root, run) do
    case AgentRuns.latest_for_task_agent(root, run["task_id"], run["agent_id"]) do
      {:ok, latest} ->
        if latest["id"] == run["id"], do: :ok, else: {:error, :superseded_agent_run}

      {:error, :not_found} ->
        :ok

      error ->
        error
    end
  end

  defp ensure_watchdog_task_open(%{"status" => status}) when status in ["done", "canceled"],
    do: {:error, :task_terminal}

  defp ensure_watchdog_task_open(_task), do: :ok

  defp ensure_no_other_active_agent_work(task, run) do
    active? =
      task
      |> Map.get("agent_work", [])
      |> Enum.any?(fn work ->
        work["id"] != run["work_id"] and
          agent_work_for_agent?(work, run["agent_id"]) and
          work["status"] in ["queued", "running"]
      end)

    if active?, do: {:error, :active_agent_work_exists}, else: :ok
  end

  defp watchdog_stale_after_seconds(opts) do
    option(opts, :stale_after_seconds)
    |> positive_integer(@watchdog_stale_after_seconds)
  end

  defp watchdog_recovery_cooldown_seconds(opts) do
    option(opts, :recovery_cooldown_seconds)
    |> positive_integer(@watchdog_recovery_cooldown_seconds)
  end

  defp seconds_from_now(seconds) do
    Clock.now()
    |> DateTime.add(seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp elapsed_seconds?(%DateTime{} = at, %DateTime{} = now, threshold) do
    DateTime.diff(now, at, :second) >= threshold
  end

  defp elapsed_seconds?(_at, _now, _threshold), do: false

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp execute_agent_work_targets(root, task, attrs, mode, targets, dispatch_plan, opts) do
    targets
    |> Enum.reduce_while({:ok, [], [], task}, fn target, {:ok, started, results, current_task} ->
      work = agent_work_for_target(attrs, mode, target, dispatch_plan, opts)
      objective = task_objective(current_task, Map.put(attrs, "agent_id", target["id"]))

      case execute_agent_work(root, current_task, work, objective, opts) do
        {:ok, result} ->
          entry = started_agent_entry(target, result)
          next_task = Map.get(result, :task, current_task)
          {:cont, {:ok, started ++ [entry], results ++ [result], next_task}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, [entry], [result], _final_task} ->
        {:ok,
         result
         |> Map.put(:started, [entry])
         |> Map.put(:dispatch_plan, dispatch_plan)}

      {:ok, started, results, final_task} ->
        {:ok,
         %{
           task: final_task,
           started: started,
           results: results,
           dispatch_plan: dispatch_plan
         }}

      error ->
        error
    end
  end

  defp execute_agent_work_batch(items, opts) do
    results =
      Enum.map(items, fn item ->
        with {:ok, ref} <- task_ref_param(item),
             {:ok, result} <- start_agent_work(ref, item, opts) do
          {:ok, result}
        else
          {:error, reason} -> {:error, agent_work_item_label(item), reason}
        end
      end)

    started =
      Enum.filter(results, fn
        {:ok, result} -> agent_work_started?(result)
        _result -> false
      end)

    failures =
      Enum.filter(results, fn
        {:error, _label, _reason} -> true
        {:ok, result} -> not agent_work_started?(result)
      end)

    if started == [] and failures != [] do
      {:error, %{"failures" => Enum.map(failures, &agent_work_batch_failure/1)}}
    else
      {:ok,
       %{
         results: Enum.map(started, fn {:ok, result} -> result end),
         failures: Enum.map(failures, &agent_work_batch_failure/1),
         started_count: length(started)
       }}
    end
  end

  defp agent_work_for_target(attrs, mode, target, dispatch_plan, opts) do
    now = Clock.iso_now()
    agent_id = target["id"]

    %{
      "id" => Clock.id("agent_work"),
      "agent_run_id" => Clock.id("agent_run"),
      "kind" => "initial",
      "status" => "running",
      "mode" => mode,
      "iteration" => 1,
      "message" => optional_text(attrs, "message"),
      "agent_id" => agent_id,
      "agent_ids" => [agent_id],
      "assignee" => target,
      "dispatch_id" => dispatch_plan["dispatch_id"],
      "dispatch_plan" => dispatch_plan,
      "task_graph_id" => optional_text(attrs, "task_graph_id", optional_text(attrs, "graph_id")),
      "task_graph_node_id" =>
        optional_text(attrs, "task_graph_node_id", optional_text(attrs, "node_id")),
      "task_graph_node_key" =>
        optional_text(attrs, "task_graph_node_key", optional_text(attrs, "node_key")),
      "source" => optional_text(attrs, "source"),
      "policy" => work_policy(attrs, opts, %{}),
      "created_at" => now,
      "started_at" => now
    }
    |> reject_empty()
  end

  defp started_agent_entry(target, result) do
    work = Map.get(result, :agent_work, %{})
    run = Map.get(result, :run, %{})

    %{
      "agent_id" => target["id"],
      "agent_name" => assignee_display_name(target),
      "agent_ref" => target["agent_ref"],
      "agent_handle" => target["agent_handle"],
      "agent_work_id" => work["id"],
      "agent_work_status" => work["status"],
      "run_id" => run["id"],
      "run_status" => run["status"]
    }
    |> reject_empty()
  end

  defp agent_work_started?(%{started: started}) when is_list(started), do: started != []
  defp agent_work_started?(%{agent_work: %{} = work}), do: work["id"] not in [nil, ""]
  defp agent_work_started?(_result), do: false

  defp agent_work_batch_failure({:error, label, reason}) do
    %{"label" => label, "reason" => inspect(reason)}
  end

  defp agent_work_batch_failure({:ok, result}) do
    task = Map.get(result, :task, %{})

    %{
      "label" => task["ref"] || "task request",
      "reason" => "no_agent_work_started"
    }
  end

  defp agent_work_request_items(params) do
    items = agent_work_item_list(params["tasks"] || params["tickets"])
    ids = normalize_string_list(params["task_ids"] || params["ticket_ids"])

    cond do
      items != [] ->
        {:batch, Enum.map(items, &merge_agent_work_item_defaults(params, &1))}

      ids != [] ->
        {:batch,
         Enum.map(ids, fn id ->
           merge_agent_work_item_defaults(params, %{"task_id" => id})
         end)}

      true ->
        {:single, params}
    end
  end

  defp agent_work_item_list(nil), do: []
  defp agent_work_item_list([]), do: []
  defp agent_work_item_list(%{} = item), do: [item]

  defp agent_work_item_list(items) when is_list(items) do
    Enum.filter(items, &is_map/1)
  end

  defp agent_work_item_list(_items), do: []

  defp merge_agent_work_item_defaults(parent, item) when is_map(item) do
    defaults =
      Map.take(parent, [
        "agent_id",
        "agent_ids",
        "agent_search",
        "agent_searches",
        "message",
        "mode",
        "policy",
        "agent_policy",
        "policy_source",
        "auto_continue",
        "continuation_allowed",
        "max_continuation_depth",
        "retry_on_failure",
        "max_agents_per_event",
        "max_agents",
        "group_token_budget",
        "request_id"
      ])

    Map.merge(defaults, string_keys(item))
  end

  defp agent_work_item_label(%{"task_id" => id}) when is_binary(id) and id != "",
    do: "task #{id}"

  defp agent_work_item_label(%{"ref" => ref}) when is_binary(ref) and ref != "",
    do: "task #{ref}"

  defp agent_work_item_label(%{"id" => id}) when is_binary(id) and id != "",
    do: "task #{id}"

  defp agent_work_item_label(_item), do: "task request"

  defp resolve_agent_work_targets(root, task, attrs) do
    assigned_agents = assigned_agent_assignees(root, task)
    active_assigned_agents = Agents.dispatchable_assignees(root, assigned_agents)

    ids =
      normalize_string_list(Map.get(attrs, "agent_ids")) ++
        normalize_string_list(Map.get(attrs, "agent_id"))

    searches =
      normalize_string_list(Map.get(attrs, "agent_searches")) ++
        normalize_string_list(Map.get(attrs, "agent_search")) ++
        normalize_string_list(Map.get(attrs, "agent"))

    cond do
      assigned_agents == [] and ids == [] and searches == [] ->
        {:ok, [default_agent_assignee()]}

      assigned_agents == [] and ids != [] ->
        resolve_unassigned_agent_ids(root, ids)

      assigned_agents == [] ->
        {:error, :no_assigned_agents}

      active_assigned_agents == [] ->
        {:error, :no_active_assigned_agents}

      ids == [] and searches == [] ->
        {:ok, active_assigned_agents}

      true ->
        with {:ok, from_ids} <- resolve_assignee_ids(ids, active_assigned_agents),
             {:ok, from_searches} <- resolve_assignee_searches(searches, active_assigned_agents) do
          {:ok, merge_assignees(from_ids, from_searches)}
        end
    end
  end

  defp assigned_agent_assignees(root, task) do
    task
    |> Map.get("assignees", [])
    |> normalize_assignees()
    |> then(&Agents.enrich_assignees(root, &1))
    |> Enum.filter(&agent_assignee?/1)
  end

  defp resolve_unassigned_agent_ids(root, ids) do
    targets = Agents.assignees_for_ids(root, ids)
    active_targets = Agents.dispatchable_assignees(root, targets)

    if active_targets == [] do
      {:error, :no_active_agents}
    else
      {:ok, active_targets}
    end
  end

  defp agent_assignee?(%{"kind" => "agent", "id" => id}) when is_binary(id) and id != "",
    do: true

  defp agent_assignee?(_assignee), do: false

  defp default_agent_assignee do
    %{"id" => @default_agent_id, "kind" => "agent", "display_name" => "Default"}
  end

  defp resolve_assignee_ids(ids, options) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Enum.find(options, &(assignee_id(&1) == id)) do
        nil -> {:halt, {:error, {:agent_not_assigned, id}}}
        assignee -> {:cont, {:ok, acc ++ [assignee]}}
      end
    end)
  end

  defp resolve_assignee_searches(searches, options) do
    Enum.reduce_while(searches, {:ok, []}, fn search, {:ok, acc} ->
      case match_assignee(search, options) do
        {:ok, assignee} -> {:cont, {:ok, acc ++ [assignee]}}
        error -> {:halt, error}
      end
    end)
  end

  defp match_assignee(search, options) do
    matches = Enum.filter(options, &assignee_matches_search?(&1, search))

    case matches do
      [assignee] -> {:ok, assignee}
      [] -> {:error, {:agent_not_assigned, search}}
      _many -> {:error, {:ambiguous_agent_search, search}}
    end
  end

  defp assignee_matches_search?(assignee, search) do
    needle = normalize_search_text(search)

    assignee
    |> assignee_search_values()
    |> Enum.map(&normalize_search_text/1)
    |> Enum.any?(fn value ->
      value == needle or (needle != "" and :binary.match(value, needle) != :nomatch)
    end)
  end

  defp assignee_search_values(assignee) do
    [
      assignee_id(assignee),
      assignee_display_name(assignee),
      assignee["agent_ref"],
      assignee["agent_handle"],
      strip_handle_prefix(assignee["agent_handle"])
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp normalize_search_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp strip_handle_prefix(<<"@", rest::binary>>), do: rest
  defp strip_handle_prefix(value), do: value

  defp assignee_id(%{} = assignee), do: assignee["id"] || assignee["agent_id"]
  defp assignee_id(_assignee), do: nil

  defp assignee_display_name(%{} = assignee) do
    assignee["display_name"] || assignee["name"] || assignee["agent_name"] ||
      assignee_id(assignee)
  end

  defp assignee_display_name(_assignee), do: nil

  defp merge_assignees(left, right) do
    (left || [])
    |> Enum.concat(right || [])
    |> Enum.reduce([], fn assignee, acc ->
      id = assignee_id(assignee)

      if id in [nil, ""] or Enum.any?(acc, &(assignee_id(&1) == id)) do
        acc
      else
        acc ++ [assignee]
      end
    end)
  end

  defp agent_work_dispatch_plan(task, targets, attrs, opts) do
    active_ids = active_agent_work_ids(task)

    AgentDispatch.plan(
      attrs
      |> Map.put("task", task)
      |> Map.put("task_id", task["id"])
      |> Map.put("task_ref", task["ref"])
      |> Map.put("event_kind", "start_agent_work")
      |> Map.put_new("source", option(opts, :source) || "task_tool")
      |> Map.put_new("max_agents_per_event", option(opts, :max_agents_per_event))
      |> Map.put_new("group_token_budget", option(opts, :group_token_budget))
      |> Map.put("candidate_agents", targets)
      |> Map.put("active_agent_ids", active_ids)
    )
  end

  defp select_dispatched_agent_targets(task, targets, dispatch_plan) do
    selected = MapSet.new(AgentDispatch.selected_agent_ids(dispatch_plan))
    dispatched = Enum.filter(targets, &MapSet.member?(selected, &1["id"]))

    if dispatched == [] do
      {:error,
       {:no_agent_work_selected,
        %{
          "task_ref" => task["ref"],
          "dispatch_id" => dispatch_plan["dispatch_id"],
          "suppressed_agents" => dispatch_plan["suppressed_agents"] || []
        }}}
    else
      {:ok, dispatched}
    end
  end

  defp active_agent_work_ids(task) do
    task
    |> Map.get("agent_work", [])
    |> Enum.filter(fn work -> work["status"] in ["queued", "running"] end)
    |> Enum.map(&(&1["agent_id"] || List.first(&1["agent_ids"] || [])))
    |> Enum.filter(&is_binary/1)
  end

  defp task_ref_param(params) do
    required_any_param(params, ["ref", "task_ref", "task_id", "id"])
  end

  defp required_any_param(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        value when is_integer(value) -> {:ok, value}
        _value -> nil
      end
    end) || {:error, {:missing_required, Enum.join(keys, "|")}}
  end

  defp work_agent_label(task, work) do
    case work["agent_id"] do
      nil -> "task:" <> task["ref"]
      "" -> "task:" <> task["ref"]
      agent_id -> "task:" <> task["ref"] <> ":" <> agent_id
    end
  end

  defp auto_continuation_message(work, decision) do
    "Auto-continue from run #{work["run_id"]} at continuation depth #{decision["depth"]}."
  end

  defp store_tasks(tasks, root) do
    ensure_store(root)
    JSON.write(tasks_path(root), tasks)
    :ok
  end

  defp store_specs(specs, root) do
    ensure_store(root)
    JSON.write(specs_index_path(root), specs)
    :ok
  end

  defp next_number(root) do
    counter = JSON.read(counter_path(root), %{"next_number" => 1})
    number = Map.get(counter, "next_number", 1)
    JSON.write(counter_path(root), %{"next_number" => number + 1})
    {:ok, number}
  end

  defp task_ref(number), do: "HW-" <> String.pad_leading(Integer.to_string(number), 2, "0")

  defp task_ref_matches?(task, ref_or_id) do
    ref = ref_or_id |> to_string() |> String.upcase()

    task["id"] == to_string(ref_or_id) or
      task["ref"] == ref or
      task["number"] == parse_ref_number(ref)
  end

  defp parse_ref_number(ref) do
    case :binary.split(ref, "-", [:global]) do
      ["HW", number] -> parse_integer(number)
      [number] -> parse_integer(number)
      _ -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp filter_status(tasks, status) when status in [nil, "", "all"], do: tasks

  defp filter_status(tasks, status) do
    Enum.filter(tasks, &(&1["status"] == status))
  end

  defp update_task(root, ref_or_id, fun) do
    tasks = load_tasks(root)

    case Enum.find(tasks, &task_ref_matches?(&1, ref_or_id)) do
      nil ->
        {:error, :task_not_found}

      task ->
        updated = fun.(task)

        tasks
        |> Enum.map(fn candidate ->
          if candidate["id"] == task["id"], do: updated, else: candidate
        end)
        |> store_tasks(root)

        {:ok, updated}
    end
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

  defp required_text(attrs, key) do
    value =
      attrs
      |> Map.get(key)
      |> to_string()
      |> String.trim()

    if value == "" do
      {:error, {:missing_required, key}}
    else
      {:ok, value}
    end
  end

  defp optional_text(attrs, key, default \\ nil) do
    value = Map.get(attrs, key, default)

    case value do
      nil ->
        default

      _ ->
        text = value |> to_string() |> String.trim()
        if text == "", do: default, else: text
    end
  end

  defp enum_value(attrs, key, allowed, default) do
    value = optional_text(attrs, key, default)

    cond do
      value in allowed -> {:ok, value}
      value in [nil, ""] -> {:error, {:missing_required, key}}
      true -> {:error, {:invalid_value, key, value, allowed}}
    end
  end

  defp estimate_value(nil), do: {:ok, nil}
  defp estimate_value(""), do: {:ok, nil}

  defp estimate_value(value) when is_integer(value) do
    if value in @estimates do
      {:ok, value}
    else
      {:error, {:invalid_value, "estimate", value, @estimates}}
    end
  end

  defp estimate_value(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> estimate_value(number)
      _ -> {:error, {:invalid_value, "estimate", value, @estimates}}
    end
  end

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    text = value |> to_string() |> String.trim()
    if text == "", do: [], else: [text]
  end

  defp normalize_labels(nil), do: []

  defp normalize_labels(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_labels/1)
    |> Enum.reduce([], fn label, acc ->
      if label_exists?(acc, label["name"]), do: acc, else: acc ++ [label]
    end)
  end

  defp normalize_labels(%{} = label) do
    label = string_keys(label)
    name = optional_text(label, "name")

    if name in [nil, ""] do
      []
    else
      [%{"name" => name, "color" => optional_text(label, "color", "#2563eb")}]
    end
  end

  defp normalize_labels(value) do
    value
    |> normalize_string_list()
    |> Enum.map(&%{"name" => &1, "color" => "#2563eb"})
  end

  defp normalize_links(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_link/1)
    |> Enum.uniq_by(&{&1["target_id"], &1["type"]})
  end

  defp normalize_links(_value), do: []

  defp normalize_link(%{} = link) do
    link = string_keys(link)
    type = optional_text(link, "type", "relates_to")
    target_id = optional_text(link, "target_id")

    cond do
      type not in @link_types ->
        []

      target_id in [nil, ""] ->
        []

      true ->
        [
          %{
            "id" => optional_text(link, "id", Clock.id("link")),
            "target_id" => target_id,
            "target_ref" => optional_text(link, "target_ref"),
            "type" => type
          }
          |> reject_empty()
        ]
    end
  end

  defp normalize_link(_value), do: []

  defp dependency_links(attrs) do
    attrs
    |> Map.get("depends_on_task_ids", Map.get(attrs, "depends_on_task_id", []))
    |> normalize_string_list()
    |> Enum.map(fn target_id ->
      %{
        "id" => Clock.id("link"),
        "target_id" => target_id,
        "type" => "depends_on"
      }
    end)
  end

  defp normalize_assignees(nil), do: []

  defp normalize_assignees(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_assignees/1)
    |> Enum.reduce([], fn assignee, acc ->
      id = assignee_id(assignee)

      if id in [nil, ""] or Enum.any?(acc, &(assignee_id(&1) == id)) do
        acc
      else
        acc ++ [assignee]
      end
    end)
  end

  defp normalize_assignees(%{} = assignee) do
    assignee = string_keys(assignee)
    id = optional_text(assignee, "id") || optional_text(assignee, "agent_id")

    if id in [nil, ""] do
      []
    else
      [
        %{
          "id" => id,
          "kind" => optional_text(assignee, "kind", "agent"),
          "display_name" =>
            optional_text(assignee, "display_name") ||
              optional_text(assignee, "name") ||
              optional_text(assignee, "agent_name") ||
              id,
          "avatar_url" => optional_text(assignee, "avatar_url"),
          "agent_ref" => optional_text(assignee, "agent_ref"),
          "agent_handle" => optional_text(assignee, "agent_handle"),
          "work_role" => optional_text(assignee, "work_role", "worker")
        }
        |> reject_empty()
      ]
    end
  end

  defp normalize_assignees(value) do
    value
    |> normalize_string_list()
    |> Enum.map(fn id ->
      %{"id" => id, "kind" => "agent", "display_name" => id, "work_role" => "worker"}
    end)
  end

  defp normalize_recurrence(nil), do: nil
  defp normalize_recurrence(""), do: nil

  defp normalize_recurrence(%{} = recurrence) do
    recurrence = string_keys(recurrence)
    frequency = optional_text(recurrence, "frequency")

    if frequency in ["daily", "weekly", "monthly"] do
      %{
        "frequency" => frequency,
        "interval" => recurrence_interval(Map.get(recurrence, "interval")),
        "timezone" => optional_text(recurrence, "timezone"),
        "ends_at" => optional_text(recurrence, "ends_at")
      }
      |> reject_empty()
    else
      nil
    end
  end

  defp normalize_recurrence(_value), do: nil

  defp recurrence_interval(nil), do: 1

  defp recurrence_interval(value) when is_integer(value) and value > 0, do: value

  defp recurrence_interval(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end

  defp normalize_metadata(%{} = metadata), do: string_keys(metadata)
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_agent_policy(%{} = policy) do
    policy
    |> string_keys()
    |> Map.take([
      "auto_continue",
      "continuation_allowed",
      "max_continuation_depth",
      "retry_on_failure",
      "source"
    ])
    |> reject_empty()
  end

  defp normalize_agent_policy(_policy), do: %{}

  defp work_policy(attrs, opts, fallback) do
    base =
      attrs
      |> Map.get("policy", Map.get(attrs, "agent_policy", fallback || %{}))
      |> normalize_agent_policy()

    base
    |> maybe_put_policy_value(
      "auto_continue",
      Map.get(attrs, "auto_continue", opts[:auto_continue])
    )
    |> maybe_put_policy_value(
      "continuation_allowed",
      Map.get(attrs, "continuation_allowed", opts[:continuation_allowed])
    )
    |> maybe_put_policy_value(
      "max_continuation_depth",
      Map.get(attrs, "max_continuation_depth", opts[:max_continuation_depth])
    )
    |> maybe_put_policy_value(
      "retry_on_failure",
      Map.get(attrs, "retry_on_failure", opts[:retry_on_failure])
    )
    |> maybe_put_policy_value("source", Map.get(attrs, "policy_source", opts[:policy_source]))
    |> reject_empty()
  end

  defp maybe_put_policy_value(policy, _key, value) when value in [nil, "", []], do: policy
  defp maybe_put_policy_value(policy, key, value), do: Map.put(policy, key, value)

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

      observed_pattern in [nil, ""] and summary in [nil, ""] and content in [nil, ""] ->
        {:error, {:missing_required, "observed_pattern_or_summary_or_content"}}

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
            "observed_pattern" => observed_pattern || summary || content,
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
    #{observed_pattern || metadata["observed_pattern"] || ""}

    Summary:
    #{summary || ""}

    Content:
    #{content || ""}

    Governance:
    - Memory scope: #{metadata["memory_scope"]}
    - Portability: #{metadata["portability"]}
    - Affects autonomy: #{metadata["affects_autonomy"]}
    """
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

        #{spec["content"] || ""}
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
    Priority: #{task["priority"] || "none"}
    Estimate: #{task["estimate"] || "none"}

    Description:
    #{task["description"] || ""}

    Recent comments:
    #{comments}

    Runtime artifacts:
    #{spec_rows}
    """
  end

  defp label_exists?(labels, name) do
    normalized = normalize_label_name(name)
    Enum.any?(labels, &(normalize_label_name(&1["name"]) == normalized))
  end

  defp normalize_label_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp ensure_not_self_link(%{"id" => id}, %{"id" => id}), do: {:error, :self_link}
  defp ensure_not_self_link(_source, _target), do: :ok

  defp ensure_new_link(source, target) do
    if Enum.any?(source["links"] || [], &(&1["target_id"] == target["id"])) do
      {:error, :duplicate_link}
    else
      :ok
    end
  end

  defp find_link(task, link_id) do
    case Enum.find(task["links"] || [], &(&1["id"] == link_id)) do
      nil -> {:error, :link_not_found}
      link -> {:ok, link}
    end
  end

  defp find_comment(task, comment_id) do
    case Enum.find(task["comments"] || [], &(&1["id"] == comment_id)) do
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

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
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

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.reduce_while({:ok, []}, fn check, {:ok, acc} ->
      check = string_keys(check)

      with {:ok, name} <- required_text(check, "name"),
           {:ok, status} <- enum_value(check, "status", @verification_statuses, nil) do
        normalized =
          %{
            "name" => name,
            "status" => status,
            "check_type" =>
              optional_text(check, "check_type", optional_text(check, "type", name)),
            "evidence" => optional_text(check, "evidence"),
            "command" => optional_text(check, "command")
          }
          |> reject_empty()

        {:cont, {:ok, [normalized | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_checks(_checks), do: {:error, :invalid_checks}

  defp verification_task_status(%{"can_finish" => true}), do: "done"
  defp verification_task_status(_route), do: "waiting"

  defp maybe_append_verification_comment(task, report, spec, attrs) do
    if truthy?(Map.get(attrs, "post_comment", true)) do
      comment = %{
        "id" => Clock.id("comment"),
        "body" => verification_comment_body(report),
        "author" => "verification",
        "created_at" => Clock.iso_now(),
        "metadata" => %{
          "kind" => "verification_route",
          "report_id" => report["id"],
          "spec_id" => spec["id"],
          "can_finish" => report["route"]["can_finish"],
          "route_status" => report["route"]["status"]
        },
        "attachments" => [
          %{
            "id" => spec["id"],
            "kind" => "spec",
            "artifact_kind" => "verification_report",
            "title" => spec["title"],
            "path" => spec["path"]
          }
        ]
      }

      Map.update(task, "comments", [comment], &(&1 ++ [comment]))
    else
      task
    end
  end

  defp verification_comment_body(report) do
    "Verification routed: #{report["route"]["status"]}. #{report["summary"]}"
    |> String.trim()
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, nil]

  defp task_objective(task, attrs) do
    message =
      optional_text(attrs, "message", "Complete this task and report concrete next steps.")

    """
    Task #{task["ref"]}: #{task["title"]}

    Status: #{task["status"]}
    Priority: #{task["priority"]}
    Kind: #{task["kind"]}

    Description:
    #{task["description"] || ""}

    Operator message:
    #{message}
    """
  end

  defp continuation_objective(task, previous_work, attrs) do
    message =
      optional_text(attrs, "message", "Continue from the prior task run and close the next gap.")

    packet =
      case Map.get(attrs, "continuation_packet") do
        packet when is_map(packet) -> Jason.encode!(packet, pretty: true)
        _missing -> "none"
      end

    """
    Continue task #{task["ref"]}: #{task["title"]}

    Previous run: #{previous_work["run_id"]}
    Previous agent work: #{previous_work["id"]}
    Continuation iteration: #{positive_integer(previous_work["iteration"], 1) + 1}

    Current task status: #{task["status"]}
    Priority: #{task["priority"]}
    Kind: #{task["kind"]}

    Description:
    #{task["description"] || ""}

    Continuation instruction:
    #{message}

    Continuation packet:
    #{packet}
    """
  end

  defp agent_work_to_continue(task, attrs) do
    work_id =
      optional_text(attrs, "previous_agent_work_id") || optional_text(attrs, "agent_work_id")

    run_id =
      optional_text(attrs, "previous_run_id") || optional_text(attrs, "previous_agent_run_id")

    agent_id =
      optional_text(attrs, "agent_id") || List.first(normalize_string_list(attrs["agent_ids"]))

    cond do
      work_id not in [nil, ""] ->
        find_agent_work_with_run(task, &(&1["id"] == work_id), :agent_work_not_found)

      run_id not in [nil, ""] ->
        find_agent_work_with_run(
          task,
          &(&1["run_id"] == run_id or &1["agent_run_id"] == run_id),
          :agent_work_not_found
        )

      agent_id not in [nil, ""] ->
        latest_agent_work_with_run(task, agent_id)

      true ->
        latest_agent_work_with_run(task)
    end
  end

  defp latest_agent_work_with_run(task, agent_id \\ nil) do
    task
    |> Map.get("agent_work", [])
    |> Enum.reverse()
    |> Enum.find(fn work ->
      valid_prior_work?(work) and agent_work_for_agent?(work, agent_id)
    end)
    |> case do
      nil -> {:error, :no_prior_agent_work}
      work -> {:ok, work}
    end
  end

  defp find_agent_work_with_run(task, predicate, not_found_reason) do
    task
    |> Map.get("agent_work", [])
    |> Enum.find(fn work -> valid_prior_work?(work) and predicate.(work) end)
    |> case do
      nil -> {:error, not_found_reason}
      work -> {:ok, work}
    end
  end

  defp agent_work_for_agent?(_work, nil), do: true
  defp agent_work_for_agent?(work, ""), do: agent_work_for_agent?(work, nil)

  defp agent_work_for_agent?(work, agent_id) do
    work["agent_id"] == agent_id or agent_id in (work["agent_ids"] || [])
  end

  defp valid_prior_work?(%{"run_id" => run_id}) when is_binary(run_id) and run_id != "", do: true
  defp valid_prior_work?(_work), do: false

  defp agent_work_status("completed"), do: "awaiting_verification"
  defp agent_work_status("blocked"), do: "blocked"
  defp agent_work_status("failed"), do: "failed"
  defp agent_work_status("canceled"), do: "canceled"
  defp agent_work_status(_status), do: "running"

  defp default_verification_gate(run) do
    %{
      "schema_version" => "holtworks_verification_gate/v1",
      "status" => "required",
      "required" => true,
      "satisfied" => false,
      "reason" => "verification_required",
      "run_status" => run["status"],
      "tool" => "tasks/verify"
    }
  end

  defp failure_verification_gate(run, reason) do
    %{
      "schema_version" => "holtworks_verification_gate/v1",
      "status" => "blocked",
      "required" => true,
      "satisfied" => false,
      "reason" => "run_not_successful",
      "run_status" => run["status"],
      "failure_reason" => inspect(reason),
      "tool" => "tasks/verify"
    }
  end

  defp summarize_output(nil), do: nil

  defp summarize_output(output) do
    output
    |> to_string()
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp task_status_after_run("canceled"), do: "canceled"
  defp task_status_after_run(_status), do: "waiting"

  defp replace_agent_work(task, work_id, replacement) do
    Map.update(task, "agent_work", [replacement], fn work_items ->
      Enum.map(work_items, fn work ->
        if work["id"] == work_id, do: replacement, else: work
      end)
    end)
  end

  defp maybe_put_artifact(work, nil), do: work

  defp maybe_put_artifact(work, artifact) do
    Map.put(work, "artifact", artifact)
  end

  defp default_spec_title(kind, task), do: task["ref"] <> " " <> kind

  defp verification_markdown(task, report) do
    check_rows =
      report["checks"]
      |> Enum.map(fn check ->
        evidence = Map.get(check, "evidence", "")

        if evidence == "" do
          "- #{check["status"]}: #{check["name"]}"
        else
          "- #{check["status"]}: #{check["name"]} - #{evidence}"
        end
      end)
      |> case do
        [] -> "- no checks recorded"
        rows -> Enum.join(rows, "\n")
      end

    """
    # Verification #{task["ref"]}

    Task: #{task["title"]}
    Decision: #{report["decision"]}

    Summary:
    #{report["summary"]}

    Checks:
    #{check_rows}
    """
  end

  defp touch(task, now \\ Clock.iso_now()) do
    Map.put(task, "updated_at", now)
  end

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp option(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp append_activity(task, type, data) do
    event = activity(type, data)
    Map.update(task, "activity", [event], &(&1 ++ [event]))
  end

  defp activity(type, data) do
    data
    |> Map.put("type", type)
    |> Map.put_new("at", Clock.iso_now())
  end

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp string_keys(value), do: value

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
