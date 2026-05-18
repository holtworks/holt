defmodule Holt.Tasks do
  @moduledoc """
  Workspace-local task flow with durable artifacts and run linkage.
  """

  alias Holt.{Agents, Clock, JSON, Paths, Runtime}

  alias Holt.Tasks.{
    ActionContract,
    ActionApi,
    ActionPreflight,
    ActionRuntimeEnvelope,
    AgentDispatch,
    AgentProfiles,
    AgentRunLog,
    AgentRunDecision,
    AgentRunFailureClassifier,
    AgentRunPolicy,
    AgentRuns,
    CapabilityContract,
    CapabilityRegistry,
    CapabilityRouter,
    ChildAgentContract,
    ConsequenceGate,
    ContextBudgetGovernor,
    ContinuationPacket,
    EvidenceLedger,
    EvidenceContract,
    GenericPlanner,
    GraphApi,
    HumanApprovalInbox,
    MobColleagueFlow,
    PlanContract,
    PlanGate,
    ProcessWakeScheduler,
    Repository,
    Store,
    TaskMemory,
    TaskGraphs,
    ActionRouter,
    ActionSession,
    Attributes,
    TeamOrchestration,
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

  def agents(opts \\ []), do: AgentProfiles.list(opts)

  def create_agent(attrs, opts \\ []) when is_map(attrs), do: AgentProfiles.create(attrs, opts)

  def update_agent(agent_id, attrs, opts \\ []) when is_map(attrs),
    do: AgentProfiles.update(agent_id, attrs, opts)

  def get_agent(agent_id, opts \\ []), do: AgentProfiles.get(agent_id, opts)

  def suspend_agent(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs),
    do: AgentProfiles.suspend(agent_id, attrs, opts)

  def resume_agent(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs),
    do: AgentProfiles.resume(agent_id, attrs, opts)

  def archive_agent(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs),
    do: AgentProfiles.archive(agent_id, attrs, opts)

  def agent_cards(opts \\ []), do: AgentProfiles.cards(opts)

  def agent_card(agent_id, opts \\ []), do: AgentProfiles.card(agent_id, opts)

  def agent_skills(agent_id, opts \\ []), do: AgentProfiles.skills(agent_id, opts)

  def action_definitions(opts \\ []), do: ActionApi.definitions(opts)

  def action_catalog(context \\ %{}, opts \\ []), do: ActionApi.catalog(context, opts)

  def agent_action_definitions(context \\ %{}, opts \\ []),
    do: ActionApi.agent_definitions(context, opts)

  def action_provider_metadata(context \\ %{}, opts \\ []),
    do: ActionApi.provider_metadata(context, opts)

  def action_provider_prompt_sections(context \\ %{}, opts \\ []),
    do: ActionApi.provider_prompt_sections(context, opts)

  def search_actions(filters \\ %{}, opts \\ []) when is_map(filters),
    do: ActionApi.search(filters, opts)

  def get_action(name, opts \\ []), do: ActionApi.get(name, opts)

  def execute_action(name, args \\ %{}, opts \\ []) when is_map(args),
    do: ActionApi.execute(name, args, opts)

  def dispatch_agent_action(name, args \\ %{}, context \\ %{}, opts \\ []) when is_map(args),
    do: ActionApi.dispatch(name, args, context, opts)

  def execute_task_action(ref_or_id, action_name, args \\ %{}, opts \\ []) when is_map(args),
    do: ActionApi.execute_task(ref_or_id, action_name, args, opts)

  def execute_task_actions(ref_or_id, calls, opts \\ []) when is_list(calls),
    do: ActionApi.execute_many(ref_or_id, calls, opts)

  def action_availability(attrs \\ %{}) when is_map(attrs), do: ActionApi.availability(attrs)

  def provider_profile(model_id, attrs \\ %{}) when is_map(attrs),
    do: ActionApi.provider_profile(model_id, attrs)

  def research_claims(opts \\ []), do: ActionApi.research_claims(opts)

  def safety_policy(attrs \\ %{}) when is_map(attrs), do: ActionApi.safety_policy(attrs)

  def runtime_context_budget(attrs \\ %{}) when is_map(attrs), do: ActionApi.context_budget(attrs)

  def recovery_contract(attrs \\ %{}) when is_map(attrs), do: ActionApi.recovery_contract(attrs)

  def run_debugger(attrs \\ %{}) when is_map(attrs), do: ActionApi.run_debugger(attrs)

  def meta_learning_snapshot(attrs \\ %{}) when is_map(attrs),
    do: ActionApi.meta_learning_snapshot(attrs)

  def agent_run_lifecycle_states, do: ActionApi.lifecycle_states()

  def agent_run_lifecycle_transition(current_state, next_state),
    do: ActionApi.lifecycle_transition(current_state, next_state)

  def agent_run_lifecycle_complete(attrs \\ %{}) when is_map(attrs),
    do: ActionApi.lifecycle_complete(attrs)

  def agent_loop_contract(attrs \\ %{}) when is_map(attrs),
    do: ActionApi.agent_loop_contract(attrs)

  def record_process_started(payload, context \\ %{}, opts \\ [])

  def record_process_started(payload, context, opts) when is_map(payload) and is_map(context),
    do: ProcessWakeScheduler.record_started(payload, context, opts)

  def record_process_started(_payload, _context, _opts), do: {:error, :invalid_process_event}

  def notify_process_terminal(payload, context \\ %{}, opts \\ [])

  def notify_process_terminal(payload, context, opts) when is_map(payload) and is_map(context),
    do: ProcessWakeScheduler.notify_terminal(payload, context, opts)

  def notify_process_terminal(_payload, _context, _opts), do: {:error, :invalid_process_event}

  def runtime_doctor(attrs \\ %{}) when is_map(attrs), do: ActionApi.doctor(attrs)

  def create(attrs, opts \\ []) when is_map(attrs), do: Repository.create(attrs, opts)

  def list(opts \\ []), do: Repository.list(opts)

  def get(ref_or_id, opts \\ []), do: Repository.get(ref_or_id, opts)

  def update(ref_or_id, attrs, opts \\ []) when is_map(attrs),
    do: Repository.update(ref_or_id, attrs, opts)

  def add_comment(ref_or_id, body, opts \\ []),
    do: Repository.add_comment(ref_or_id, body, opts)

  def delete_comment(ref_or_id, comment_id, opts \\ []),
    do: Repository.delete_comment(ref_or_id, comment_id, opts)

  def add_label(ref_or_id, attrs, opts \\ []) when is_map(attrs),
    do: Repository.add_label(ref_or_id, attrs, opts)

  def remove_label(ref_or_id, name, opts \\ []),
    do: Repository.remove_label(ref_or_id, name, opts)

  def add_link(ref_or_id, target_ref_or_id, type, opts \\ []),
    do: Repository.add_link(ref_or_id, target_ref_or_id, type, opts)

  def remove_link(ref_or_id, link_id, opts \\ []),
    do: Repository.remove_link(ref_or_id, link_id, opts)

  def set_estimate(ref_or_id, estimate, opts \\ []),
    do: Repository.set_estimate(ref_or_id, estimate, opts)

  def set_priority(ref_or_id, priority, opts \\ []),
    do: Repository.set_priority(ref_or_id, priority, opts)

  def save_spec(ref_or_id, attrs, opts \\ []) when is_map(attrs),
    do: Repository.save_spec(ref_or_id, attrs, opts)

  def list_specs(ref_or_id, opts \\ []), do: Repository.list_specs(ref_or_id, opts)

  def get_spec(spec_id, opts \\ []), do: Repository.get_spec(spec_id, opts)

  def save_teammate_memory(ref_or_id, attrs, opts \\ []) when is_map(attrs),
    do: Repository.save_teammate_memory(ref_or_id, attrs, opts)

  def load_teammate_runtime(ref_or_id, opts \\ []),
    do: Repository.load_teammate_runtime(ref_or_id, opts)

  def read_memory_artifact(artifact_ref, opts \\ []),
    do: Repository.read_memory_artifact(artifact_ref, opts)

  def record_task_memory_artifact(ref_or_id, attrs, opts \\ []) when is_map(attrs),
    do: Repository.record_task_memory_artifact(ref_or_id, attrs, opts)

  def task_memory_context(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts) do
      TaskMemory.context_packet(root, task, task_memory_context_attrs(root, task, attrs, opts))
    end
  end

  def context_budget(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, _task} <- get(ref_or_id, opts) do
      if context_budget_attrs?(attrs) do
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

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, previous_work} <- agent_work_to_continue(task, attrs) do
      previous_run = agent_run_for_work(root, task["id"], previous_work)
      context_packet = task_memory_context_packet(root, task, attrs, opts)

      {:ok,
       build_continuation_packet(task, previous_work, previous_run, context_packet, attrs, opts)}
    end
  end

  defp context_budget_attrs?(attrs) do
    Enum.any?(
      [Map.has_key?(attrs, "messages"), Map.has_key?(attrs, "estimated_input_tokens")],
      & &1
    )
  end

  def agent_runs(opts \\ []), do: AgentRunLog.list(opts)

  def agent_run_events(opts \\ []), do: AgentRunLog.events(opts)

  def agent_run_event_log(run_or_id, opts \\ []), do: AgentRunLog.event_log(run_or_id, opts)

  def agent_runs_by_agent(agent_id, opts \\ []), do: AgentRunLog.by_agent(agent_id, opts)

  def agent_run_events_by_agent(agent_id, filters \\ %{}, opts \\ []) when is_map(filters) do
    AgentRunLog.events_by_agent(agent_id, filters, opts)
  end

  def agent_run_replay(agent_id, run_or_id, opts \\ []),
    do: AgentRunLog.replay(agent_id, run_or_id, opts)

  def agent_run_task_inspector(task_ref_or_id, opts \\ []),
    do: AgentRunLog.task_inspector(task_ref_or_id, opts)

  def record_agent_run_event(run_or_id, attrs, opts \\ [])

  def record_agent_run_event(run_or_id, attrs, opts),
    do: AgentRunLog.record_event(run_or_id, attrs, opts)

  def record_agent_run_continuation_packet(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    AgentRunLog.record_continuation_packet(run_or_id, attrs, opts)
  end

  def record_agent_run_narration(run_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    AgentRunLog.record_narration(run_or_id, attrs, opts)
  end

  def record_agent_run_plan_contract(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    AgentRunLog.record_plan_contract(run_or_id, attrs, opts)
  end

  def record_agent_run_child_contract(run_or_id, attrs, opts \\ []) when is_map(attrs) do
    AgentRunLog.record_child_contract(run_or_id, attrs, opts)
  end

  def record_agent_run_child_completion(run_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    AgentRunLog.record_child_completion(run_or_id, attrs, opts)
  end

  def record_agent_run_action_event(run_or_id, attrs, opts \\ [])

  def record_agent_run_action_event(run_or_id, attrs, opts),
    do: AgentRunLog.record_action_event(run_or_id, attrs, opts)

  def record_agent_run_objective_evaluation(run_or_id, attrs, opts \\ [])

  def record_agent_run_objective_evaluation(run_or_id, attrs, opts),
    do: AgentRunLog.record_objective_evaluation(run_or_id, attrs, opts)

  def task_graphs(ref_or_id, opts \\ []), do: GraphApi.list(ref_or_id, opts)

  def get_task_graph(graph_id, opts \\ []), do: GraphApi.get(graph_id, opts)

  def create_task_graph(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs),
    do: GraphApi.create(ref_or_id, attrs, opts)

  def advance_task_graph(graph_id, attrs \\ %{}, opts \\ []) when is_map(attrs),
    do: GraphApi.advance(graph_id, attrs, opts)

  def complete_task_graph_node(graph_id, node_ref, attrs \\ %{}, opts \\ []) when is_map(attrs),
    do: GraphApi.complete_node(graph_id, node_ref, attrs, opts)

  def block_task_graph_node(graph_id, node_ref, attrs \\ %{}, opts \\ []) when is_map(attrs),
    do: GraphApi.block_node(graph_id, node_ref, attrs, opts)

  def evidence_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts) do
      {:ok, evidence_contract_for_task(root, task, attrs)}
    end
  end

  def verification_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts) do
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

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
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

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
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

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
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

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, _task} <- get(ref_or_id, opts),
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

  def action_session(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts) do
      {:ok,
       ActionSession.build(
         attrs
         |> Map.take(
           ~w(session_id agent_id agent_ref agent_handle agent_name run_id agent_run_id graph_id source policy_profile enabled_action_groups disabled_action_groups disabled_actions direct_actions connected_accounts todos workbench preload_actions)
         )
         |> Map.put("task", task)
         |> Map.put("workspace", root)
       )}
    end
  end

  def action_session_prompt(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, session} <- action_session(ref_or_id, attrs, opts) do
      {:ok, ActionSession.prompt_section(session)}
    end
  end

  def action_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, session} <- route_action_session(ref_or_id, attrs, opts) do
      {:ok,
       ActionContract.build(
         attrs
         |> Map.put("action_session", session)
       )}
    end
  end

  def route_action(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, session} <- route_action_session(ref_or_id, attrs, opts) do
      {:ok,
       ActionRouter.route(
         attrs
         |> Map.put("action_session", session)
       )}
    end
  end

  def plan_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, session} <- route_action_session(ref_or_id, attrs, opts),
         {:ok, _graph} <- maybe_plan_graph(root, task, attrs) do
      contract_attrs =
        attrs
        |> Map.take(
          ~w(plan_id status allowed_effect_scopes allow_workspace_durable allowed_actions plan_steps created_at)
        )
        |> Map.put("task", task)
        |> Map.put("action_session", session)
        |> Map.put("evidence_contract", evidence_contract_for_task(root, task, attrs))

      {:ok, PlanContract.build(contract_attrs)}
    end
  end

  def plan_gate(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, route} <- route_action(ref_or_id, attrs, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      {:ok,
       PlanGate.evaluate(%{
         "action_route" => route,
         "action_contract" => route["action_contract"],
         "plan_contract" => plan
       })}
    end
  end

  def action_preflight(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, route} <- route_action(ref_or_id, attrs, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      gate =
        PlanGate.evaluate(%{
          "action_route" => route,
          "action_contract" => route["action_contract"],
          "plan_contract" => plan
        })

      {:ok,
       ActionPreflight.evaluate(
         attrs
         |> Map.put("action_route", route)
         |> Map.put("action_contract", route["action_contract"])
         |> Map.put("plan_contract", plan)
         |> Map.put("plan_gate", gate)
       )}
    end
  end

  def consequence_gate(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, runtime_attrs} <- action_runtime_attrs(ref_or_id, attrs, opts) do
      {:ok, ConsequenceGate.evaluate(runtime_attrs)}
    end
  end

  def action_runtime_envelope(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, runtime_attrs} <- action_runtime_attrs(ref_or_id, attrs, opts) do
      {:ok, ActionRuntimeEnvelope.propose(runtime_attrs)}
    end
  end

  def capability_registry(action_name, attrs \\ %{}) when is_map(attrs) do
    {:ok, CapabilityRegistry.lookup(action_name, attrs)}
  end

  def capability_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, capability_attrs} <- capability_attrs(ref_or_id, attrs, opts) do
      {:ok, CapabilityContract.build(capability_attrs)}
    end
  end

  def capability_route(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, contract} <- capability_contract(ref_or_id, attrs, opts) do
      route_attrs =
        attrs
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

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, task_graph} <- maybe_plan_graph(root, task, attrs) do
      agent_runs = AgentRuns.list_for_task(task["id"], workspace: root)

      {:ok,
       WorkGraph.build(%{
         "task" => task,
         "task_graph" => task_graph,
         "agent_runs" => agent_runs,
         "events" => agent_run_events_for_task(root, task),
         "verification_gate" => graph_gate(task_graph),
         "child_agent_contracts" => attrs["child_agent_contracts"],
         "prediction_errors" => attrs["prediction_errors"]
       })}
    end
  end

  def work_graph_gate(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, graph} <- work_graph(ref_or_id, attrs, opts) do
      {:ok,
       WorkGraph.completion_gate(%{
         "work_graph" => graph,
         "verification_gate" => graph["completion_gate"]
       })}
    end
  end

  def work_graph_budget(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, targets} <- resolve_agent_work_targets(root, task, attrs) do
      {:ok,
       WorkGraphBudget.build(
         attrs
         |> Map.put("task", task)
         |> Map.put("candidate_agents", targets)
       )}
    end
  end

  def work_graph_schedule(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, graph} <- work_graph(ref_or_id, attrs, opts) do
      {:ok,
       WorkGraphScheduler.schedule(
         attrs
         |> Map.take(~w(policy_decision repair_orchestration completed_node_ids node_statuses))
         |> Map.put("work_graph", graph)
         |> Map.put("verification_gate", graph["completion_gate"])
       )}
    end
  end

  def agent_dispatch_plan(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, targets} <- resolve_agent_work_targets(root, task, attrs) do
      {:ok, agent_work_dispatch_plan(task, targets, attrs, opts)}
    end
  end

  def team_orchestration(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts) do
      {:ok,
       TeamOrchestration.plan(
         attrs
         |> Map.put("task", task)
         |> Map.put_new("estimate", task["estimate"])
       )}
    end
  end

  def schedule_mob_colleague_flow(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, scheduled} <- MobColleagueFlow.schedule(root, ref_or_id, attrs, opts) do
      maybe_start_mob_colleague_observation(root, scheduled, opts)
    end
  end

  def child_agent_contract(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      action =
        case action_contract_for_child(ref_or_id, attrs, opts) do
          {:ok, contract} -> contract
          {:error, _reason} -> %{}
        end

      attrs
      |> Map.put("task", task)
      |> Map.put("plan_contract", plan)
      |> Map.put("action_contract", action)
      |> Map.put(
        "evidence_contract",
        evidence_contract_for_task(Paths.workspace_root(opts), task, attrs)
      )
      |> Map.put("context", child_agent_context(task, attrs))
      |> ChildAgentContract.build()
      |> child_agent_contract_result()
    end
  end

  def delegate_to_agent(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, role} <- required_text(attrs, "role"),
         {:ok, system_prompt} <- required_text(attrs, "system_prompt"),
         {:ok, instructions} <- required_text(attrs, "instructions") do
      attrs =
        attrs
        |> Map.put("role", role)
        |> Map.put("work_role", optional_text(attrs, "work_role"))
        |> Map.put("system_prompt", system_prompt)
        |> Map.put("instructions", instructions)

      with {:ok, contract} <-
             delegation_child_contract(ref_or_id, "delegate_to_agent", attrs, opts),
           {:ok, child_task} <- create_delegated_task(ref_or_id, "delegate_to_agent", attrs, opts) do
        delegation_id = Clock.id("agent_delegation")
        maybe_record_parent_child_contract(root, opts, contract)

        attrs
        |> delegated_agent_work_attrs("delegate_to_agent", contract, delegation_id, child_task)
        |> start_delegated_agent_work(child_task["ref"], "delegate_to_agent", opts)
        |> delegated_agent_result(
          "holt_task_agent_delegation/v1",
          "delegation_id",
          delegation_id,
          attrs,
          contract,
          child_task,
          root,
          opts
        )
      end
    end
  end

  def invoke_agent(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, agent_id} <- required_text(attrs, "agent_id"),
         {:ok, profile} <- Agents.get(root, agent_id),
         :ok <- ensure_task_agent_invokable(profile),
         {:ok, instructions} <- required_text(attrs, "instructions"),
         {:ok, target_skill} <- required_text(attrs, "target_skill"),
         {:ok, validation_contract} <- required_text(attrs, "validation_contract") do
      attrs =
        attrs
        |> Map.put("agent_id", profile["id"])
        |> Map.put("target_agent_id", profile["id"])
        |> Map.put("target_skill", target_skill)
        |> Map.put("instructions", instructions)
        |> Map.put("validation_contract", validation_contract)
        |> Map.put("agent_card", Agents.profile_card(profile))
        |> Map.put("system_prompt", profile["instructions"])
        |> reject_empty()

      with {:ok, contract} <- delegation_child_contract(ref_or_id, "invoke_agent", attrs, opts),
           {:ok, child_task} <- create_delegated_task(ref_or_id, "invoke_agent", attrs, opts) do
        invocation_id = Clock.id("agent_invocation")
        maybe_record_parent_child_contract(root, opts, contract)

        attrs
        |> delegated_agent_work_attrs("invoke_agent", contract, invocation_id, child_task)
        |> start_delegated_agent_work(child_task["ref"], "invoke_agent", opts)
        |> delegated_agent_result(
          "holt_task_agent_invocation/v1",
          "invocation_id",
          invocation_id,
          attrs,
          contract,
          child_task,
          root,
          opts
        )
      end
    end
  end

  def complete_action_runtime_envelope(envelope, attrs \\ %{})

  def complete_action_runtime_envelope(envelope, attrs) when is_map(envelope) and is_map(attrs) do
    {:ok, ActionRuntimeEnvelope.complete(envelope, attrs)}
  end

  def complete_action_runtime_envelope(_envelope, _attrs), do: {:error, :invalid_envelope}

  def action_approval_request(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, envelope} <- action_runtime_envelope(ref_or_id, attrs, opts) do
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

    with {:ok, request} <- canonical_attrs(request),
         {:ok, attrs} <- canonical_attrs(attrs) do
      resolution = HumanApprovalInbox.resolve(request, attrs)
      {:ok, persist_action_approval_resolution(root, request, resolution)}
    end
  end

  def resolve_action_approval_request(request_id, attrs, opts)
      when is_binary(request_id) and is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs) do
      case find_action_approval_request(root, request_id) do
        nil ->
          {:error, :approval_request_not_found}

        request ->
          resolution = HumanApprovalInbox.resolve(request, attrs)
          {:ok, persist_action_approval_resolution(root, request, resolution)}
      end
    end
  end

  def resolve_action_approval_request(_request_or_id, _attrs, _opts),
    do: {:error, :invalid_approval_request}

  def action_evidence_ledger(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
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

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, mode} <- enum_value(attrs, "mode", @agent_modes, "work"),
         {:ok, targets} <- resolve_agent_work_targets(root, task, attrs),
         dispatch_plan = agent_work_dispatch_plan(task, targets, attrs, opts),
         {:ok, selected_targets} <- select_dispatched_agent_targets(task, targets, dispatch_plan) do
      execute_agent_work_targets(root, task, attrs, mode, selected_targets, dispatch_plan, opts)
    end
  end

  def start_agent_work_batch(params, opts \\ []) when is_map(params) do
    with {:ok, params} <- canonical_attrs(params) do
      case agent_work_request_items(params) do
        {:single, item} ->
          with {:ok, ref} <- task_ref_param(item) do
            start_agent_work(ref, item, opts)
          end

        {:batch, items} ->
          execute_agent_work_batch(items, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def continue_agent_work(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, previous_work} <- agent_work_to_continue(task, attrs),
         {:ok, mode} <- enum_value(attrs, "mode", @agent_modes, previous_work_mode(previous_work)) do
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
          Map.put(attrs, "continuation_depth", iteration),
          opts
        )

      attrs = Map.put(attrs, "continuation_packet", continuation_packet)

      agent_ids =
        attrs
        |> Map.get("agent_ids", previous_agent_ids(previous_work))
        |> normalize_string_list()

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
          "agent_id" => List.first(agent_ids),
          "assignee" => previous_work["assignee"],
          "dispatch_id" => previous_work["dispatch_id"],
          "dispatch_plan" => previous_work["dispatch_plan"],
          "task_graph_id" => continuation_graph_id(attrs, previous_work),
          "task_graph_node_id" => continuation_node_id(attrs, previous_work),
          "task_graph_node_key" => continuation_node_key(attrs, previous_work),
          "source" => optional_text(attrs, "source"),
          "context_packet_id" => context_packet["packet_id"],
          "continuation_packet" => continuation_packet,
          "policy" => work_policy(attrs, opts, previous_work["policy"]),
          "created_at" => now,
          "started_at" => now,
          "last_activity_at" => now
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
      |> Keyword.put(:agent_id, work["agent_id"])
      |> Keyword.put(:task_id, task["id"])
      |> Keyword.put(:task_ref, task["ref"])
      |> Keyword.put(:agent_run_id, work["agent_run_id"])

    case Runtime.run(objective, run_opts) do
      {:ok, %{run: run, artifact: artifact} = result} ->
        completed_at = Clock.iso_now()

        final_work =
          work
          |> Map.put("status", agent_work_status(run["status"]))
          |> Map.put("run_id", run["id"])
          |> Map.put("run_dir", run["run_dir"])
          |> maybe_put_artifact(artifact)
          |> Map.put("completed_at", completed_at)
          |> Map.put("last_activity_at", completed_at)

        classification = AgentRunFailureClassifier.classify(run)
        policy = AgentRunPolicy.for_task(task, final_work)
        finished_task_graph = finish_work_graph_node(root, final_work, run, result)

        decision =
          continuation_decision(run, classification, policy, final_work)

        {:ok, _agent_run} =
          AgentRuns.record_completed(root, task, final_work, run, %{
            "verification_gate" => default_verification_gate(run),
            "output_summary" => summarize_output(result_output(result)),
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

        task_graph = selected_task_graph(finished_task_graph, running_task_graph)

        base_result =
          result
          |> Map.put(:task, enrich_task(root, final_task))
          |> Map.put(:agent_work, enrich_agent_work(final_work))
          |> Map.put(:continuation_decision, decision)
          |> Map.put(:task_graph, task_graph)
          |> Map.put(:task_graph_gate, graph_gate(task_graph))

        with {:ok, mob_result, mob_task} <-
               maybe_start_mob_colleague_reviews(
                 root,
                 final_task,
                 final_work,
                 run,
                 base_result,
                 opts
               ) do
          maybe_auto_continue(root, mob_task, final_work, decision, mob_result, opts)
        end

      {:error, %{run: run, reason: reason}} ->
        completed_at = Clock.iso_now()

        final_work =
          work
          |> Map.put("status", agent_work_status(run["status"]))
          |> Map.put("run_id", run["id"])
          |> Map.put("run_dir", run["run_dir"])
          |> Map.put("failure_reason", inspect(reason))
          |> Map.put("completed_at", completed_at)
          |> Map.put("last_activity_at", completed_at)

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

        task_graph = selected_task_graph(failed_task_graph, running_task_graph)

        error_result = %{
          task: enrich_task(root, final_task),
          run: run,
          reason: reason,
          agent_work: enrich_agent_work(final_work),
          continuation_decision: decision,
          task_graph: task_graph,
          task_graph_gate: graph_gate(task_graph)
        }

        case decision["action"] do
          "continue" ->
            maybe_auto_continue(root, final_task, final_work, decision, error_result, opts)

          _action ->
            {:error, error_result}
        end

      {:error, reason} ->
        completed_at = Clock.iso_now()

        final_work =
          work
          |> Map.put("status", "failed")
          |> Map.put("failure_reason", inspect(reason))
          |> Map.put("completed_at", completed_at)
          |> Map.put("last_activity_at", completed_at)

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

        task_graph = selected_task_graph(failed_task_graph, running_task_graph)

        {:error,
         %{
           task: enrich_task(root, final_task),
           reason: reason,
           agent_work: enrich_agent_work(final_work),
           task_graph: task_graph,
           task_graph_gate: graph_gate(task_graph)
         }}
    end
  end

  def route_verification(ref_or_id, attrs, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
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
          "schema_version" => "holt_verification_report/v1",
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

  def tasks_path(root), do: Store.tasks_path(root)
  def counter_path(root), do: Store.counter_path(root)
  def specs_index_path(root), do: Store.specs_index_path(root)
  def agents_path(root), do: Store.agents_path(root)
  def agent_events_path(root), do: Store.agent_events_path(root)
  def agent_runs_path(root), do: Store.agent_runs_path(root)
  def agent_run_events_path(root), do: Store.agent_run_events_path(root)
  def task_graphs_path(root), do: Store.task_graphs_path(root)
  def task_graph_events_path(root), do: Store.task_graph_events_path(root)
  def verifier_calibrations_path(root), do: Store.verifier_calibrations_path(root)

  defp ensure_store(root), do: Store.ensure(root)

  defp load_specs(root), do: Store.load_specs(root)

  defp enrich_task(root, task), do: Store.enrich_task(root, task)

  defp enrich_agent_work(work), do: Store.enrich_agent_work(work)

  defp graph_gate(nil), do: nil
  defp graph_gate(graph), do: graph["mission_control"]

  defp selected_task_graph(primary, _secondary) when is_map(primary), do: primary
  defp selected_task_graph(_primary, secondary), do: secondary

  defp agent_run_events_for_task(root, task) do
    root
    |> AgentRuns.event_log()
    |> Enum.filter(&task_event?(task, &1))
  end

  defp task_event?(task, event) do
    Enum.any?([event["task_id"] == task["id"], event["task_ref"] == task["ref"]], & &1)
  end

  defp action_contract_for_child(ref_or_id, attrs, opts) do
    case optional_text(attrs, "action") do
      action_name when action_name in [nil, ""] ->
        {:ok, %{}}

      _action_name ->
        action_contract(ref_or_id, attrs, opts)
    end
  end

  defp child_agent_context(task, attrs) do
    %{
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "parent_task_id" => task["parent_id"],
      "agent_id" => optional_text(attrs, "agent_id"),
      "run_id" => optional_text(attrs, "run_id")
    }
    |> reject_empty()
  end

  defp child_agent_contract_result({:error, _reason} = error), do: error
  defp child_agent_contract_result(contract) when is_map(contract), do: {:ok, contract}

  defp delegation_child_contract(ref_or_id, action_name, attrs, opts) do
    contract_args =
      attrs
      |> Map.put("child_ref", child_ref(action_name, attrs))
      |> Map.put("target_agent_id", optional_text(attrs, "target_agent_id"))
      |> Map.put("allowed_actions", normalize_string_list(attrs["allowed_actions"]))
      |> reject_empty()

    child_agent_contract(
      ref_or_id,
      %{
        "action" => action_name,
        "arguments" => contract_args,
        "agent_id" => opts[:agent_id],
        "run_id" => opts[:agent_run_id],
        "source" => action_name
      },
      opts
    )
  end

  defp child_ref("invoke_agent", attrs), do: optional_text(attrs, "target_agent_id")
  defp child_ref("delegate_to_agent", attrs), do: optional_text(attrs, "role")
  defp child_ref(_action_name, attrs), do: optional_text(attrs, "child_ref")

  defp create_delegated_task(ref_or_id, action_name, attrs, opts) do
    root = Paths.workspace_root(opts)

    with {:ok, parent_task} <- get(ref_or_id, opts),
         {:ok, assignee} <- delegated_task_assignee(root, action_name, attrs, opts) do
      create(delegated_task_attrs(parent_task, action_name, attrs, assignee), opts)
    end
  end

  defp delegated_task_attrs(parent_task, action_name, attrs, assignee) do
    %{
      "title" => delegated_task_title(parent_task, action_name, attrs),
      "description" => delegated_task_description(parent_task, action_name, attrs),
      "status" => "todo",
      "kind" => "task",
      "priority" => parent_task["priority"],
      "estimate" => parent_task["estimate"],
      "origin" => action_name,
      "parent_id" => parent_task["id"],
      "assignees" => [assignee],
      "labels" => delegated_task_labels(parent_task),
      "agent_policy" => normalize_agent_policy(Map.get(attrs, "policy", %{}))
    }
    |> reject_empty()
  end

  defp delegated_task_title(parent_task, action_name, attrs) do
    case optional_text(attrs, "task_title") do
      value when value in [nil, ""] ->
        default_delegated_task_title(parent_task, action_name, attrs)

      value ->
        value
    end
  end

  defp default_delegated_task_title(parent_task, "invoke_agent", attrs) do
    agent_id = optional_text(attrs, "target_agent_id", optional_text(attrs, "agent_id", "agent"))
    "Invoke #{agent_id} for #{parent_task["ref"]}"
  end

  defp default_delegated_task_title(parent_task, "delegate_to_agent", attrs) do
    role = optional_text(attrs, "work_role", optional_text(attrs, "role", "agent"))
    "Delegate #{role} work for #{parent_task["ref"]}"
  end

  defp default_delegated_task_title(parent_task, _action_name, _attrs) do
    "Delegated work for #{parent_task["ref"]}"
  end

  defp delegated_task_description(parent_task, action_name, attrs) do
    [
      "Parent task: #{parent_task["ref"]} #{parent_task["title"]}",
      "Delegation action: #{action_name}",
      text_section("Instructions", optional_text(attrs, "instructions")),
      text_section("Validation contract", optional_text(attrs, "validation_contract")),
      text_section("Target skill", optional_text(attrs, "target_skill"))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp delegated_task_labels(parent_task) do
    parent_labels =
      parent_task
      |> Map.get("labels", [])
      |> Enum.filter(&is_map/1)

    delegated_label = %{"name" => "delegated-agent-work", "color" => "#7c3aed"}

    if Enum.any?(parent_labels, &(&1["name"] == delegated_label["name"])) do
      parent_labels
    else
      parent_labels ++ [delegated_label]
    end
  end

  defp delegated_task_assignee(root, action_name, attrs, opts) do
    with {:ok, agent_id} <- delegated_task_agent_id(action_name, attrs, opts) do
      assignee =
        root
        |> Agents.assignees_for_ids([agent_id])
        |> List.first()
        |> Map.put("work_role", delegated_task_work_role(action_name, attrs))

      {:ok, assignee}
    end
  end

  defp delegated_task_agent_id("invoke_agent", attrs, _opts) do
    required_text(attrs, "target_agent_id")
  end

  defp delegated_task_agent_id("delegate_to_agent", attrs, opts) do
    {:ok, delegated_target_agent_id(attrs, opts)}
  end

  defp delegated_task_agent_id(_action_name, _attrs, _opts), do: {:ok, @default_agent_id}

  defp current_agent_id(opts) do
    case opts[:agent_id] do
      agent_id when is_binary(agent_id) and agent_id != "" -> agent_id
      _missing -> nil
    end
  end

  defp delegated_target_agent_id(attrs, opts) do
    case optional_text(attrs, "target_agent_id") do
      value when value in [nil, ""] ->
        case current_agent_id(opts) do
          agent_id when is_binary(agent_id) and agent_id != "" -> agent_id
          _missing -> @default_agent_id
        end

      value ->
        value
    end
  end

  defp delegated_task_work_role(action_name, attrs) do
    case optional_text(attrs, "work_role") do
      value when value in [nil, ""] -> ChildAgentContract.work_role(attrs, action_name)
      value -> value
    end
  end

  defp delegated_work_agent_id(child_task) do
    child_task
    |> Map.get("assignees", [])
    |> normalize_assignees()
    |> List.first()
    |> case do
      %{"id" => id} when is_binary(id) and id != "" -> id
      %{"agent_id" => agent_id} when is_binary(agent_id) and agent_id != "" -> agent_id
      _missing -> @default_agent_id
    end
  end

  defp child_completion_status(run, work) do
    case run["status"] do
      value when value in [nil, ""] -> work["status"]
      value -> value
    end
  end

  defp delegated_agent_work_attrs(attrs, action_name, child_contract, request_id, child_task) do
    target_agent_id = delegated_work_agent_id(child_task)

    %{
      "message" => delegated_agent_message(action_name, attrs, child_contract),
      "mode" => optional_text(attrs, "mode", "work"),
      "source" => action_name,
      "request_id" => request_id,
      "agent_id" => target_agent_id,
      "max_agents_per_event" => 1,
      "child_agent_contract" => child_contract,
      "target_skill" => optional_text(attrs, "target_skill"),
      "work_role" => optional_text(attrs, "work_role"),
      "validation_contract" => optional_text(attrs, "validation_contract"),
      "allowed_actions" => normalize_string_list(attrs["allowed_actions"]),
      "input_artifacts" => normalize_string_list(attrs["input_artifacts"]),
      "expected_output_artifacts" => normalize_string_list(attrs["expected_output_artifacts"]),
      "handoff_requirements" => normalize_string_list(attrs["handoff_requirements"]),
      "max_autonomy" => optional_text(attrs, "max_autonomy")
    }
    |> put_request_id(action_name, request_id)
    |> reject_empty()
  end

  defp put_request_id(work_attrs, "delegate_to_agent", request_id),
    do: Map.put(work_attrs, "delegation_id", request_id)

  defp put_request_id(work_attrs, "invoke_agent", request_id),
    do: Map.put(work_attrs, "invocation_id", request_id)

  defp put_request_id(work_attrs, _action_name, _request_id), do: work_attrs

  defp delegated_agent_message(action_name, attrs, child_contract) do
    [
      "Child agent action: #{action_name}",
      text_section("Role", optional_text(attrs, "work_role", optional_text(attrs, "role"))),
      text_section("Target agent", optional_text(attrs, "target_agent_id")),
      text_section("Target skill", optional_text(attrs, "target_skill")),
      text_section("System prompt", optional_text(attrs, "system_prompt")),
      text_section("Instructions", optional_text(attrs, "instructions")),
      text_section("Validation contract", optional_text(attrs, "validation_contract")),
      text_section("Allowed actions", normalize_string_list(attrs["allowed_actions"])),
      text_section("Child contract", Jason.encode!(child_contract, pretty: true))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp text_section(_title, value) when value in [nil, "", []], do: nil

  defp text_section(title, values) when is_list(values),
    do: "#{title}: " <> Enum.join(values, ", ")

  defp text_section(title, value), do: "#{title}:\n#{value}"

  defp start_delegated_agent_work(work_attrs, ref_or_id, action_name, opts) do
    start_agent_work(ref_or_id, work_attrs, Keyword.put(opts, :source, action_name))
  end

  defp delegated_agent_result(
         {:ok, result},
         schema_version,
         id_key,
         id,
         attrs,
         child_contract,
         child_task,
         root,
         opts
       ) do
    maybe_record_parent_child_completion(root, opts, result)

    {:ok,
     %{
       "schema_version" => schema_version,
       id_key => id,
       "status" => "completed",
       "role" => optional_text(attrs, "role"),
       "work_role" => optional_text(attrs, "work_role"),
       "agent_id" => optional_text(attrs, "target_agent_id"),
       "target_skill" => optional_text(attrs, "target_skill"),
       "validation_contract" => optional_text(attrs, "validation_contract"),
       "child_agent_contract" => child_contract,
       "created_task" => child_task,
       "delegated_task" => result_task(result),
       "agent_work" => result_work(result),
       "agent_run" => result_run(result),
       "task" => result_task(result),
       "output" => result_output(result),
       "started" => optional_result(result, :started),
       "dispatch_plan" => optional_result(result, :dispatch_plan),
       "task_graph" => optional_result(result, :task_graph),
       "task_graph_gate" => optional_result(result, :task_graph_gate),
       "created_at" => Clock.iso_now()
     }
     |> reject_empty()}
  end

  defp delegated_agent_result(
         {:error, reason},
         _schema_version,
         _id_key,
         _id,
         _attrs,
         _child_contract,
         _child_task,
         _root,
         _opts
       ),
       do: {:error, delegated_agent_failure_reason(reason)}

  defp delegated_agent_failure_reason(%{reason: reason}), do: reason
  defp delegated_agent_failure_reason(%{"reason" => reason}), do: reason
  defp delegated_agent_failure_reason(reason), do: reason

  defp maybe_record_parent_child_contract(root, opts, child_contract) do
    case opts[:agent_run_id] do
      run_id when is_binary(run_id) and run_id != "" ->
        case AgentRuns.record_child_agent_contract(root, run_id, child_contract) do
          {:ok, _run, _event} -> :ok
          {:duplicate, _run, _event} -> :ok
          {:error, _reason} -> :ok
        end

      _missing ->
        :ok
    end
  end

  defp maybe_record_parent_child_completion(root, opts, result) do
    work = result_work(result)
    run = result_run(result)

    attrs =
      %{
        "child_agent_id" => work["agent_id"],
        "child_agent_work_id" => work["id"],
        "child_run_id" => run["id"],
        "status" => child_completion_status(run, work),
        "message" => "Child task-agent work completed."
      }
      |> reject_empty()

    maybe_emit_parent_child_completion(opts, attrs)

    case opts[:agent_run_id] do
      run_id when is_binary(run_id) and run_id != "" ->
        case AgentRuns.record_child_agent_completion(root, run_id, attrs) do
          {:ok, _run, _event} -> :ok
          {:duplicate, _run, _event} -> :ok
          {:error, _reason} -> :ok
        end

      _missing ->
        :ok
    end
  end

  defp maybe_emit_parent_child_completion(opts, attrs) do
    case opts[:runtime_event_callback] do
      callback when is_function(callback, 1) ->
        attrs
        |> Map.put("type", "child_agent.completed")
        |> Map.put("agent_run_id", opts[:agent_run_id])
        |> reject_empty()
        |> callback.()

      _missing ->
        :ok
    end
  end

  defp ensure_task_agent_invokable(%{"status" => "active", "lifecycle_state" => "active"}),
    do: :ok

  defp ensure_task_agent_invokable(%{"status" => "active"}), do: :ok
  defp ensure_task_agent_invokable(_profile), do: {:error, :agent_not_invokable}

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
    case optional_text(attrs, "graph_id") do
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
    case optional_text(attrs, "graph_id") do
      graph_id when graph_id not in [nil, ""] ->
        TaskGraphs.get(root, graph_id)

      _missing ->
        {:ok, TaskGraphs.list_for_task(root, task["id"]) |> List.last()}
    end
  end

  defp calibration_assignment(ref_or_id, attrs, opts) do
    cond do
      Map.has_key?(attrs, "assignment") ->
        {:error, {:unsupported_argument, "assignment"}}

      is_map(Map.get(attrs, "verifier_assignment")) ->
        assignment = Map.get(attrs, "verifier_assignment")

        case canonical_map?(assignment) do
          true -> {:ok, assignment}
          false -> {:error, :invalid_verifier_assignment}
        end

      true ->
        verifier_assignment(ref_or_id, attrs, opts)
    end
  end

  defp verifier_available_agents(root, task, attrs) do
    source =
      case Map.get(attrs, "available_agents") do
        agents when is_list(agents) and agents != [] -> agents
        _missing -> Map.get(task, "assignees", [])
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

  defp route_action_session(ref_or_id, attrs, opts) do
    case {Map.fetch(attrs, "action_session"), Map.fetch(attrs, "session")} do
      {{:ok, _session}, {:ok, _legacy_session}} ->
        {:error, :unsupported_session_argument}

      {{:ok, session}, :error} when is_map(session) ->
        {:ok, ActionSession.build(session)}

      {{:ok, _session}, :error} ->
        {:error, :invalid_action_session}

      {:error, {:ok, _legacy_session}} ->
        {:error, :unsupported_session_argument}

      {:error, :error} ->
        action_session(ref_or_id, attrs, opts)
    end
  end

  defp action_runtime_attrs(ref_or_id, attrs, opts) do
    with {:ok, task} <- get(ref_or_id, opts),
         {:ok, route} <- route_action(ref_or_id, attrs, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      gate =
        PlanGate.evaluate(%{
          "action_route" => route,
          "action_contract" => route["action_contract"],
          "plan_contract" => plan
        })

      preflight =
        ActionPreflight.evaluate(
          attrs
          |> Map.put("action_route", route)
          |> Map.put("action_contract", route["action_contract"])
          |> Map.put("plan_contract", plan)
          |> Map.put("plan_gate", gate)
        )

      {:ok,
       attrs
       |> Map.put("task", task)
       |> Map.put("context", action_runtime_context(task, attrs))
       |> Map.put("action_route", route)
       |> Map.put("action_contract", route["action_contract"])
       |> Map.put("plan_contract", plan)
       |> Map.put("plan_gate", gate)
       |> Map.put("action_preflight", preflight)}
    end
  end

  defp evidence_envelope(ref_or_id, attrs, opts) do
    case Map.get(attrs, "action_runtime_envelope") do
      envelope when is_map(envelope) ->
        case canonical_map?(envelope) do
          true -> {:ok, envelope}
          false -> {:error, :invalid_action_runtime_envelope}
        end

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
      ~w(result result_status execution_observation observed_changes observed_state_changes),
      &Map.has_key?(attrs, &1)
    )
  end

  defp normalize_evidence_completion_attrs(attrs) do
    attrs
    |> maybe_put_result_from_status()
  end

  defp maybe_put_result_from_status(%{"result" => _result} = attrs), do: attrs

  defp maybe_put_result_from_status(attrs) do
    status = Map.get(attrs, "result_status")

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
    case get(request["task_id"], workspace: root) do
      {:ok, task} ->
        TaskMemory.record_artifact(root, task, %{
          "kind" => "human_approval_request",
          "title" => "Approval request #{request["approval_request_id"]}",
          "content" => Jason.encode!(request, pretty: true),
          "source" => "action_approval_request",
          "metadata" => %{
            "approval_request_id" => request["approval_request_id"],
            "action_name" => request["action_name"],
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
        "action_name" => ledger["source_action_name"]
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
    get_in(envelope, ["action_contract", "target_refs", "task_ref"])
  end

  defp envelope_task_id(envelope) do
    get_in(envelope, ["action_contract", "target_refs", "task_id"])
  end

  defp capability_attrs(ref_or_id, attrs, opts) do
    root = Paths.workspace_root(opts)

    with {:ok, attrs} <- canonical_attrs(attrs),
         {:ok, task} <- get(ref_or_id, opts),
         {:ok, session} <- route_action_session(ref_or_id, attrs, opts),
         {:ok, plan} <- plan_contract(ref_or_id, attrs, opts) do
      {:ok,
       attrs
       |> Map.put("task", task)
       |> Map.put("workspace", root)
       |> Map.put("action_session", session)
       |> Map.put("plan_contract", plan)
       |> Map.put("evidence_contract", evidence_contract_for_task(root, task, attrs))
       |> Map.put("available_agents", available_capability_agents(task, attrs))}
    end
  end

  defp available_capability_agents(task, attrs) do
    case Map.get(attrs, "available_agents") do
      agents when is_list(agents) and agents != [] ->
        agents

      agents when is_binary(agents) and agents != "" ->
        normalize_string_list(agents)

      _missing ->
        Map.get(task, "assignees", [])
    end
  end

  defp action_runtime_context(task, attrs) do
    %{
      "autonomous" => Map.get(attrs, "autonomous", true),
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "parent_task_id" => task["parent_id"],
      "agent_id" => optional_text(attrs, "agent_id", "default"),
      "agent_ref" => optional_text(attrs, "agent_ref"),
      "run_id" => optional_text(attrs, "run_id"),
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
    content_limit = positive_integer(memory_content_limit(attrs, opts), 1_600)

    specs =
      root
      |> load_specs()
      |> Enum.filter(&(&1["task_id"] == task["id"]))
      |> Enum.filter(&(&1["kind"] in @runtime_spec_kinds))
      |> Enum.map(&maybe_include_spec_content(&1, root, true, content_limit))

    attrs
    |> Map.put("specs", specs)
    |> Map.put("agent_runs", AgentRuns.list_for_task(task["id"], workspace: root))
    |> Map.put_new("policy", Map.get(task, "agent_policy", %{}))
  end

  defp memory_content_limit(attrs, opts) do
    case Map.get(attrs, "content_limit") do
      value when value in [nil, ""] -> option(opts, :content_limit)
      value -> value
    end
  end

  defp task_memory_context_packet(root, task, attrs, opts) do
    case TaskMemory.context_packet(root, task, task_memory_context_attrs(root, task, attrs, opts)) do
      {:ok, packet} ->
        packet

      {:error, _reason} ->
        %{
          "schema_version" => "holt_task_memory_context_packet/v1",
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
    |> Enum.find(&run_matches_work?(&1, work))
  end

  defp run_matches_work?(run, work) do
    Enum.any?(
      [
        run["id"] == work["agent_run_id"],
        run["work_id"] == work["id"],
        run["run_id"] == work["run_id"]
      ],
      & &1
    )
  end

  defp build_continuation_packet(task, previous_work, previous_run, context_packet, attrs, opts) do
    agent_run =
      case previous_run do
        run when is_map(run) -> run
        _missing -> %{}
      end

    %{
      "task" => continuation_task(task),
      "agent_work" => continuation_agent_work(previous_work),
      "agent_run" => continuation_agent_run(agent_run),
      "context_packet" => context_packet,
      "continuation_depth" => attrs["continuation_depth"],
      "source" => continuation_source(attrs, opts),
      "resources" => %{
        "workspace_required" => true,
        "task_memory_artifact_refs" => Map.get(context_packet, "artifact_refs", [])
      }
    }
    |> reject_empty()
    |> ContinuationPacket.build()
  end

  defp continuation_task(task) do
    %{
      "id" => task["id"],
      "ref" => task["ref"]
    }
    |> reject_empty()
  end

  defp continuation_agent_work(work) do
    %{
      "id" => work["id"],
      "run_id" => work["run_id"],
      "agent_id" => work["agent_id"],
      "agent_ref" => work["agent_ref"]
    }
    |> reject_empty()
  end

  defp continuation_agent_run(run) do
    %{
      "id" => run["id"]
    }
    |> reject_empty()
  end

  defp continuation_source(attrs, opts) do
    case optional_text(attrs, "source") do
      nil ->
        case option(opts, :source) do
          nil -> "task_agent_continuation"
          source -> source
        end

      source ->
        source
    end
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
               "summary" => summarize_output(result_output(result)),
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
               "code" => blocker_code(work),
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
    node_ref = work_graph_node_ref(work)

    if graph_id in [nil, ""] do
      nil
    else
      {graph_id, node_ref}
    end
  end

  defp blocker_code(work) do
    case work["blocker_code"] do
      value when value in [nil, ""] -> "agent_work_failed"
      value -> value
    end
  end

  defp work_graph_node_ref(work) do
    case work["task_graph_node_id"] do
      value when value in [nil, ""] -> task_graph_node_key(work)
      value -> value
    end
  end

  defp task_graph_node_key(work) do
    case work["task_graph_node_key"] do
      value when value in [nil, ""] -> "work"
      value -> value
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
         |> Map.put(:task, result_task(continuation))
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

  defp maybe_start_mob_colleague_observation(root, scheduled, opts) do
    case Map.get(scheduled, "observation_start_request") do
      %{"flow_id" => flow_id, "observation_task_ref" => ref, "agent_work_attrs" => attrs} =
          request ->
        case start_agent_work(ref, attrs, opts) do
          {:ok, observation_result} ->
            case MobColleagueFlow.mark_observation_agent_work_started(
                   root,
                   scheduled["task"],
                   flow_id,
                   observation_result
                 ) do
              {:ok, updated_task} ->
                {:ok,
                 scheduled
                 |> Map.put("task", enrich_task(root, updated_task))
                 |> Map.put("observation_agent_work", result_work(observation_result))
                 |> Map.put("observation_run", result_run(observation_result))
                 |> Map.put(
                   "observation_start",
                   mob_colleague_start_summary("observation", request, observation_result)
                 )}

              {:error, reason} ->
                {:ok, Map.put(scheduled, "observation_start_error", inspect(reason))}
            end

          {:error, reason} ->
            case MobColleagueFlow.mark_observation_agent_work_failed(
                   root,
                   scheduled["task"],
                   flow_id,
                   reason
                 ) do
              {:ok, updated_task} ->
                {:ok,
                 scheduled
                 |> Map.put("task", enrich_task(root, updated_task))
                 |> Map.put("observation_start_error", inspect(reason))}

              {:error, _update_reason} ->
                {:ok, Map.put(scheduled, "observation_start_error", inspect(reason))}
            end
        end

      _missing ->
        {:ok, scheduled}
    end
  end

  defp maybe_start_mob_colleague_reviews(root, task, work, run, result, opts) do
    case MobColleagueFlow.trigger_after_work(root, task, work, run, opts) do
      {:ok, %{flow_results: [], task: updated_task}} ->
        {:ok, result, updated_task}

      {:ok, %{task: updated_task, flow_results: flow_results, start_requests: start_requests}} ->
        {final_task, starts, errors} =
          start_mob_colleague_review_work(root, updated_task, start_requests, opts)

        result =
          result
          |> Map.put(:task, enrich_task(root, final_task))
          |> Map.put(:mob_colleague_flows, flow_results)
          |> maybe_put_result(:mob_colleague_review_starts, starts)
          |> maybe_put_result(:mob_colleague_review_errors, errors)

        {:ok, result, final_task}
    end
  end

  defp start_mob_colleague_review_work(root, task, start_requests, opts) do
    Enum.reduce(start_requests, {task, [], []}, fn request, {current_task, starts, errors} ->
      flow_id = request["flow_id"]
      ref = request["review_task_ref"]
      attrs = map_value(request["agent_work_attrs"])

      case start_agent_work(ref, attrs, opts) do
        {:ok, review_result} ->
          case MobColleagueFlow.mark_review_agent_work_started(
                 root,
                 current_task,
                 flow_id,
                 review_result
               ) do
            {:ok, updated_task} ->
              {updated_task,
               starts ++ [mob_colleague_start_summary("review", request, review_result)], errors}

            {:error, reason} ->
              {current_task, starts,
               errors ++ [mob_colleague_start_error("review", request, reason)]}
          end

        {:error, reason} ->
          next_task =
            case MobColleagueFlow.mark_review_agent_work_failed(
                   root,
                   current_task,
                   flow_id,
                   reason
                 ) do
              {:ok, updated_task} -> updated_task
              {:error, _update_reason} -> current_task
            end

          {next_task, starts, errors ++ [mob_colleague_start_error("review", request, reason)]}
      end
    end)
  end

  defp mob_colleague_start_summary(kind, request, result) do
    work = result_work(result)
    run = result_run(result)

    %{
      "kind" => kind,
      "flow_id" => request["flow_id"],
      "task_ref" => mob_colleague_request_task_ref(kind, request),
      "agent_work_id" => work["id"],
      "agent_work_status" => work["status"],
      "run_id" => run["id"],
      "run_status" => run["status"]
    }
    |> reject_empty()
  end

  defp mob_colleague_start_error(kind, request, reason) do
    %{
      "kind" => kind,
      "flow_id" => request["flow_id"],
      "task_ref" => mob_colleague_request_task_ref(kind, request),
      "reason" => inspect(reason)
    }
  end

  defp mob_colleague_request_task_ref("review", request), do: request["review_task_ref"]
  defp mob_colleague_request_task_ref(_kind, request), do: request["observation_task_ref"]

  defp maybe_put_result(result, _key, value) when value in [nil, "", [], %{}], do: result
  defp maybe_put_result(result, key, value), do: Map.put(result, key, value)

  defp result_task(%{task: task}) when is_map(task), do: task

  defp result_task(result),
    do: raise(ArgumentError, "task result missing :task: #{inspect(result)}")

  defp result_work(%{agent_work: work}) when is_map(work), do: work

  defp result_work(result),
    do: raise(ArgumentError, "task result missing :agent_work: #{inspect(result)}")

  defp result_run(%{run: run}) when is_map(run), do: run

  defp result_run(result),
    do: raise(ArgumentError, "task result missing :run: #{inspect(result)}")

  defp result_output(%{output: output}), do: output

  defp result_output(result),
    do: raise(ArgumentError, "task result missing :output: #{inspect(result)}")

  defp optional_result(result, key) when is_map(result) do
    case Map.fetch(result, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp evaluate_watchdog_run(root, run, opts) do
    now = watchdog_now(opts)
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
        "recovery_agent_work_id" => result_work(recovery_result)["id"],
        "recovery_run_id" => result_run(recovery_result)["id"]
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
             "continuation_agent_work_id" => result_work(continuation)["id"],
             "continuation_run_id" => result_run(continuation)["id"]
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
      "schema_version" => "holt_agent_process_wake/v1",
      "source" => @process_wake_source,
      "reason" => reason,
      "previous_agent_run_id" => run["id"],
      "previous_runtime_run_id" => run["run_id"],
      "previous_agent_work_id" => run["work_id"],
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "task_title" => task["title"],
      "task_status" => task["status"],
      "agent_id" => run["agent_id"],
      "process_event_id" => event["id"],
      "process_event_kind" => event["type"],
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
      "schema_version" => "holt_agent_run_watchdog_recovery/v1",
      "source" => @watchdog_recovery_source,
      "reason" => reason,
      "previous_agent_run_id" => run["id"],
      "previous_runtime_run_id" => run["run_id"],
      "previous_agent_work_id" => run["work_id"],
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "task_title" => task["title"],
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

  defp watchdog_now(opts) do
    case option(opts, :now) do
      nil -> Clock.now()
      now -> now
    end
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
          next_task = result_task(result)
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
      "task_graph_id" => optional_text(attrs, "graph_id"),
      "task_graph_node_id" => optional_text(attrs, "node_id"),
      "task_graph_node_key" => optional_text(attrs, "node_key"),
      "source" => optional_text(attrs, "source"),
      "child_agent_contract" => map_value(attrs["child_agent_contract"]),
      "delegation_id" => optional_text(attrs, "delegation_id"),
      "invocation_id" => optional_text(attrs, "invocation_id"),
      "target_skill" => optional_text(attrs, "target_skill"),
      "work_role" => optional_text(attrs, "work_role", target["work_role"]),
      "validation_contract" => optional_text(attrs, "validation_contract"),
      "allowed_actions" => normalize_string_list(attrs["allowed_actions"]),
      "policy" => work_policy(attrs, opts, %{}),
      "created_at" => now,
      "started_at" => now,
      "last_activity_at" => now
    }
    |> reject_empty()
  end

  defp started_agent_entry(target, result) do
    work = result_work(result)
    run = result_run(result)

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

  defp agent_work_batch_failure({:ok, %{task: task}}) do
    %{
      "label" => agent_work_result_label(task),
      "reason" => "no_agent_work_started"
    }
  end

  defp agent_work_batch_failure({:ok, _result}) do
    %{"label" => "task request", "reason" => "no_agent_work_started"}
  end

  defp agent_work_result_label(task) do
    case task["ref"] do
      value when value in [nil, ""] -> "task request"
      value -> value
    end
  end

  defp agent_work_request_items(params) do
    cond do
      Map.has_key?(params, "tickets") ->
        {:error, {:unsupported_argument, "tickets"}}

      Map.has_key?(params, "task_ids") ->
        {:error, {:unsupported_argument, "task_ids"}}

      Map.has_key?(params, "ticket_ids") ->
        {:error, {:unsupported_argument, "ticket_ids"}}

      agent_work_item_list(params["tasks"]) != [] ->
        items = agent_work_item_list(params["tasks"])
        {:batch, Enum.map(items, &merge_agent_work_item_defaults(params, &1))}

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

    Map.merge(defaults, item)
  end

  defp agent_work_item_label(%{"ref" => ref}) when is_binary(ref) and ref != "",
    do: "task #{ref}"

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
      assignee_search_match?(value, needle)
    end)
  end

  defp assignee_search_match?(value, needle) do
    Enum.any?([value == needle, substring_match?(value, needle)], & &1)
  end

  defp substring_match?(_value, ""), do: false
  defp substring_match?(value, needle), do: :binary.match(value, needle) != :nomatch

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

  defp assignee_id(%{} = assignee), do: assignee["agent_id"]
  defp assignee_id(_assignee), do: nil

  defp assignee_display_name(%{} = assignee) do
    case assignee["display_name"] do
      value when value in [nil, ""] -> assignee_id(assignee)
      value -> value
    end
  end

  defp assignee_display_name(_assignee), do: nil

  defp merge_assignees(left, right) do
    left
    |> Enum.concat(right)
    |> Enum.reduce([], fn assignee, acc ->
      id = assignee_id(assignee)

      if invalid_or_duplicate_assignee?(id, acc) do
        acc
      else
        acc ++ [assignee]
      end
    end)
  end

  defp invalid_or_duplicate_assignee?(id, assignees) do
    Enum.any?([id in [nil, ""], Enum.any?(assignees, &(assignee_id(&1) == id))], & &1)
  end

  defp agent_work_dispatch_plan(task, targets, attrs, opts) do
    active_ids = active_agent_work_ids(task)

    AgentDispatch.plan(
      attrs
      |> Map.take(
        ~w(max_agents_per_event group_token_budget work_graph_id machine_db_id enabled_action_groups cooldown_seconds forced_decision_after_turns)
      )
      |> Map.put("task", task)
      |> Map.put("event", dispatch_event(attrs, opts))
      |> put_default_dispatch_value("max_agents_per_event", option(opts, :max_agents_per_event))
      |> put_default_dispatch_value("group_token_budget", option(opts, :group_token_budget))
      |> Map.put("candidate_agents", Enum.map(targets, &agent_work_candidate/1))
      |> Map.put("active_agent_ids", active_ids)
      |> reject_empty()
    )
  end

  defp dispatch_event(attrs, opts) do
    %{
      "event_kind" => "start_agent_work",
      "source" => dispatch_source(opts),
      "request_id" => attrs["request_id"]
    }
    |> reject_empty()
  end

  defp dispatch_source(opts) do
    case option(opts, :source) do
      value when value in [nil, ""] -> "action"
      value -> value
    end
  end

  defp put_default_dispatch_value(attrs, key, value) do
    case Map.has_key?(attrs, key) do
      true -> attrs
      false -> Map.put(attrs, key, value)
    end
  end

  defp agent_work_candidate(assignee) do
    %{
      "agent_id" => assignee["id"],
      "agent_ref" => assignee["agent_ref"],
      "agent_handle" => assignee["agent_handle"],
      "display_name" => assignee["display_name"],
      "kind" => assignee["kind"],
      "work_role" => assignee["work_role"],
      "status" => assignee["status"],
      "lifecycle_state" => assignee["lifecycle_state"],
      "skills" => assignee["skills"],
      "model" => assignee["model"],
      "provider" => assignee["provider"],
      "agent_card" => assignee["agent_card"]
    }
    |> reject_empty()
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
          "suppressed_agents" => Map.get(dispatch_plan, "suppressed_agents", [])
        }}}
    else
      {:ok, dispatched}
    end
  end

  defp active_agent_work_ids(task) do
    task
    |> Map.get("agent_work", [])
    |> Enum.filter(fn work -> work["status"] in ["queued", "running"] end)
    |> Enum.map(& &1["agent_id"])
    |> Enum.filter(&is_binary/1)
  end

  defp task_ref_param(params) do
    cond do
      Map.has_key?(params, "task_ref") ->
        {:error, {:unsupported_argument, "task_ref"}}

      Map.has_key?(params, "task_id") ->
        {:error, {:unsupported_argument, "task_id"}}

      Map.has_key?(params, "id") ->
        {:error, {:unsupported_argument, "id"}}

      true ->
        case Map.get(params, "ref") do
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> {:error, {:missing_required, "ref"}}
              ref -> {:ok, ref}
            end

          nil ->
            {:error, {:missing_required, "ref"}}

          _value ->
            {:error, {:invalid_argument, "ref"}}
        end
    end
  end

  defp auto_continuation_message(work, decision) do
    "Auto-continue from run #{work["run_id"]} at continuation depth #{decision["depth"]}."
  end

  defp update_task(root, ref_or_id, fun), do: Store.update_task(root, ref_or_id, fun)

  defp required_text(attrs, key), do: Attributes.required_text(attrs, key)

  defp optional_text(attrs, key, default \\ nil),
    do: Attributes.optional_text(attrs, key, default)

  defp enum_value(attrs, key, allowed, default),
    do: Attributes.enum_value(attrs, key, allowed, default)

  defp normalize_string_list(value), do: Attributes.normalize_string_list(value)

  defp normalize_assignees(value), do: Attributes.normalize_assignees(value)

  defp normalize_metadata(value), do: Attributes.normalize_metadata(value)

  defp normalize_agent_policy(value), do: Attributes.normalize_agent_policy(value)

  defp work_policy(attrs, opts, fallback) do
    attrs
    |> policy_base(fallback)
    |> maybe_put_policy_value("auto_continue", policy_value(attrs, opts, "auto_continue"))
    |> maybe_put_policy_value(
      "continuation_allowed",
      policy_value(attrs, opts, "continuation_allowed")
    )
    |> maybe_put_policy_value(
      "max_continuation_depth",
      policy_value(attrs, opts, "max_continuation_depth")
    )
    |> maybe_put_policy_value("retry_on_failure", policy_value(attrs, opts, "retry_on_failure"))
    |> maybe_put_policy_value("source", policy_value(attrs, opts, "policy_source"))
    |> reject_empty()
  end

  defp policy_base(%{"policy" => policy}, _fallback) when is_map(policy),
    do: normalize_agent_policy(policy)

  defp policy_base(_attrs, fallback),
    do: fallback |> work_policy_default() |> normalize_agent_policy()

  defp work_policy_default(value) when is_map(value), do: value
  defp work_policy_default(_value), do: %{}

  defp policy_value(attrs, opts, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> policy_opt(opts, key)
    end
  end

  defp policy_opt(opts, "auto_continue"), do: Keyword.get(opts, :auto_continue)
  defp policy_opt(opts, "continuation_allowed"), do: Keyword.get(opts, :continuation_allowed)
  defp policy_opt(opts, "max_continuation_depth"), do: Keyword.get(opts, :max_continuation_depth)
  defp policy_opt(opts, "retry_on_failure"), do: Keyword.get(opts, :retry_on_failure)
  defp policy_opt(opts, "policy_source"), do: Keyword.get(opts, :policy_source)

  defp maybe_put_policy_value(policy, _key, value) when value in [nil, "", []], do: policy
  defp maybe_put_policy_value(policy, key, value), do: Map.put(policy, key, value)

  defp maybe_include_spec_content(spec, root, true, content_limit) do
    limit = positive_integer(content_limit, 12_000)
    path = Path.join(root, spec["path"])
    content = File.read!(path) |> String.slice(0, limit)
    Map.put(spec, "content", content)
  end

  defp positive_integer(value, default), do: Attributes.positive_integer(value, default)

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.reduce_while({:ok, []}, fn
      check, {:ok, acc} when is_map(check) ->
        with {:ok, name} <- required_text(check, "name"),
             {:ok, check_type} <- required_text(check, "check_type"),
             {:ok, status} <- enum_value(check, "status", @verification_statuses, nil) do
          normalized =
            %{
              "name" => name,
              "status" => status,
              "check_type" => check_type,
              "evidence" => optional_text(check, "evidence"),
              "command" => optional_text(check, "command")
            }
            |> reject_empty()

          {:cont, {:ok, [normalized | acc]}}
        else
          error -> {:halt, error}
        end

      _check, {:ok, _acc} ->
        {:halt, {:error, :invalid_check}}
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

  defp truthy?(value), do: Attributes.truthy?(value)

  defp task_objective(task, attrs) do
    message =
      optional_text(attrs, "message", "Complete this task and report concrete next steps.")

    """
    Task #{task["ref"]}: #{task["title"]}

    Status: #{task["status"]}
    Priority: #{task["priority"]}
    Kind: #{task["kind"]}

    Description:
    #{task_description(task)}

    Operator message:
    #{message}

    Recent task comments:
    #{task_objective_comments(task)}

    Mob colleague guidance:
    #{task_objective_mob_colleague_guidance(task)}
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
    #{task_description(task)}

    Continuation instruction:
    #{message}

    Recent task comments:
    #{task_objective_comments(task)}

    Mob colleague guidance:
    #{task_objective_mob_colleague_guidance(task)}

    Continuation packet:
    #{packet}
    """
  end

  defp task_objective_comments(task) do
    task
    |> Map.get("comments", [])
    |> Enum.take(-8)
    |> Enum.map(fn comment ->
      author = comment_author(comment)
      body = comment_body(comment)
      "- #{author}: #{String.slice(to_string(body), 0, 500)}"
    end)
    |> case do
      [] -> "- none"
      rows -> Enum.join(rows, "\n")
    end
  end

  defp task_description(task) do
    case task["description"] do
      value when value in [nil, ""] -> ""
      value -> value
    end
  end

  defp comment_author(comment) do
    case comment["author"] do
      value when value in [nil, ""] -> "unknown"
      value -> value
    end
  end

  defp comment_body(comment) do
    case comment["body"] do
      value when value in [nil, ""] -> ""
      value -> value
    end
  end

  defp task_objective_mob_colleague_guidance(task) do
    task
    |> Map.get("mob_colleague_flows", [])
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(&1["status"] in ["armed", "observing", "review_task_created"]))
    |> Enum.map(fn flow ->
      "- #{flow["colleague_agent_id"]}: treat task comments as live review input; call get_task and load_teammate_runtime before finalizing so new colleague feedback can redirect the work."
    end)
    |> case do
      [] -> "- none"
      rows -> Enum.join(rows, "\n")
    end
  end

  defp agent_work_to_continue(task, attrs) do
    work_id = optional_text(attrs, "previous_agent_work_id")
    run_id = optional_text(attrs, "previous_run_id")
    agent_id = optional_text(attrs, "agent_id")

    cond do
      work_id not in [nil, ""] ->
        find_agent_work_with_run(task, &(&1["id"] == work_id), :agent_work_not_found)

      run_id not in [nil, ""] ->
        find_agent_work_with_run(
          task,
          &agent_work_run?(&1, run_id),
          :agent_work_not_found
        )

      agent_id not in [nil, ""] ->
        latest_agent_work_with_run(task, agent_id)

      true ->
        latest_agent_work_with_run(task)
    end
  end

  defp previous_work_mode(work) do
    case work["mode"] do
      mode when mode in @agent_modes -> mode
      _missing -> "work"
    end
  end

  defp previous_agent_ids(work) do
    case work["agent_ids"] do
      ids when is_list(ids) and ids != [] -> ids
      _missing -> [@default_agent_id]
    end
  end

  defp continuation_graph_id(attrs, previous_work) do
    case optional_text(attrs, "graph_id") do
      value when value in [nil, ""] -> previous_work["task_graph_id"]
      value -> value
    end
  end

  defp continuation_node_id(attrs, previous_work) do
    case optional_text(attrs, "node_id") do
      value when value in [nil, ""] -> previous_work["task_graph_node_id"]
      value -> value
    end
  end

  defp continuation_node_key(attrs, previous_work) do
    case optional_text(attrs, "node_key") do
      value when value in [nil, ""] -> previous_work["task_graph_node_key"]
      value -> value
    end
  end

  defp agent_work_run?(work, run_id) do
    Enum.any?([work["run_id"] == run_id, work["agent_run_id"] == run_id], & &1)
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
    Enum.any?([work["agent_id"] == agent_id, agent_id in Map.get(work, "agent_ids", [])], & &1)
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
      "schema_version" => "holt_verification_gate/v1",
      "status" => "required",
      "required" => true,
      "satisfied" => false,
      "reason" => "verification_required",
      "run_status" => run["status"],
      "action" => "tasks/verify"
    }
  end

  defp failure_verification_gate(run, reason) do
    %{
      "schema_version" => "holt_verification_gate/v1",
      "status" => "blocked",
      "required" => true,
      "satisfied" => false,
      "reason" => "run_not_successful",
      "run_status" => run["status"],
      "failure_reason" => inspect(reason),
      "action" => "tasks/verify"
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
  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp option(_opts, _key), do: nil

  defp map_value(value) when is_map(value) do
    case canonical_map?(value) do
      true -> value
      false -> %{}
    end
  end

  defp map_value(_value), do: %{}

  defp canonical_attrs(attrs) do
    if canonical_map?(attrs), do: {:ok, attrs}, else: {:error, :invalid_attrs}
  end

  defp canonical_map?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_map?(_value), do: false

  defp canonical_value?(value) when is_map(value), do: canonical_map?(value)
  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp append_activity(task, type, data) do
    event = activity(type, data)
    Map.update(task, "activity", [event], &(&1 ++ [event]))
  end

  defp activity(type, data) do
    data
    |> Map.put("type", type)
    |> Map.put_new("at", Clock.iso_now())
  end

  defp reject_empty(map), do: Attributes.reject_empty(map)
end
