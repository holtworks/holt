defmodule HoltWorks.AgentRuntime do
  @moduledoc """
  Unified local runtime contract facade for HoltWorks task-agent orchestration.
  """

  alias HoltWorks.Tasks

  alias HoltWorks.Tasks.{
    ActionContract,
    ActionPreflight,
    ActionRuntimeEnvelope,
    AgentDispatch,
    AgentLoop,
    AgentRunStateMachine,
    CapabilityContract,
    CapabilityIndex,
    CapabilityRegistry,
    CapabilityRouter,
    ChildAgentContract,
    ContextBudget,
    ContextBudgetGovernor,
    ConsequenceGate,
    ConsequencePredictor,
    ContinuationPacket,
    EvidenceContract,
    EvidenceLedger,
    ExecutionObservation,
    GenericPlanner,
    HumanApprovalInbox,
    MetaLearningLoop,
    OutcomeCalibration,
    OutputSanitizer,
    PlanContract,
    PlanGate,
    PolicyEngine,
    PredictionError,
    ProcessWakeScheduler,
    ProviderRegistry,
    RecoveryContract,
    RepairOrchestrator,
    RunDebugger,
    SafetyPolicy,
    StateInvariantCheck,
    StateReconciliation,
    StateTransitionPrediction,
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
    WorkGraphScheduler,
    WorldStateSnapshot
  }

  def tool_availability(attrs \\ %{}), do: ToolRegistry.snapshot(attrs)

  def capability_registry_entry(tool_name, attrs \\ %{}),
    do: CapabilityRegistry.lookup(tool_name, attrs)

  def capability_registry, do: CapabilityRegistry.all()

  def action_contract(attrs \\ %{}), do: ActionContract.build(attrs)
  def action_preflight(attrs \\ %{}), do: ActionPreflight.evaluate(attrs)
  def action_runtime_envelope(attrs \\ %{}), do: ActionRuntimeEnvelope.propose(attrs)
  def action_runtime_envelope_route(attrs \\ %{}), do: ActionRuntimeEnvelope.route(attrs)

  def complete_action_runtime_envelope(envelope, attrs \\ %{}),
    do: ActionRuntimeEnvelope.complete(envelope, attrs)

  def repair_orchestration(attrs \\ %{}), do: RepairOrchestrator.orchestrate(attrs)
  def human_approval_request(attrs \\ %{}), do: HumanApprovalInbox.build_request(attrs)

  def human_approval_resolution(request, attrs \\ %{}),
    do: HumanApprovalInbox.resolve(request, attrs)

  def evidence_ledger(attrs \\ %{}), do: EvidenceLedger.build(attrs)
  def work_graph_schedule(attrs \\ %{}), do: WorkGraphScheduler.schedule(attrs)
  def child_agent_contract(attrs \\ %{}), do: ChildAgentContract.build(attrs)
  def capability_contract(attrs \\ %{}), do: CapabilityContract.build(attrs)
  def agent_capability_profiles(agent_or_map), do: CapabilityIndex.profiles(agent_or_map)
  def capability_route(attrs \\ %{}), do: CapabilityRouter.route(attrs)
  def plan_contract(attrs \\ %{}), do: PlanContract.build(attrs)
  def generic_plan(attrs \\ %{}), do: GenericPlanner.build(attrs)
  def plan_gate(attrs \\ %{}), do: PlanGate.evaluate(attrs)
  def plan_gate_route(attrs \\ %{}), do: PlanGate.evaluate(attrs)
  def policy_decision(attrs \\ %{}), do: PolicyEngine.evaluate(attrs)
  def policy_decision_route(attrs \\ %{}), do: PolicyEngine.evaluate(attrs)
  def consequence_prediction(attrs \\ %{}), do: ConsequencePredictor.predict(attrs)
  def consequence_gate(attrs \\ %{}), do: ConsequenceGate.evaluate(attrs)
  def consequence_gate_route(attrs \\ %{}), do: ConsequenceGate.route(attrs)
  def execution_observation(attrs \\ %{}), do: ExecutionObservation.from_result(attrs)
  def prediction_error(attrs \\ %{}), do: PredictionError.compare(attrs)
  def outcome_calibration(attrs \\ %{}), do: OutcomeCalibration.build(attrs)
  def world_state_snapshot(attrs \\ %{}), do: WorldStateSnapshot.build(attrs)
  def state_transition_prediction(attrs \\ %{}), do: StateTransitionPrediction.predict(attrs)
  def state_invariant_check(attrs \\ %{}), do: StateInvariantCheck.evaluate(attrs)
  def state_reconciliation(attrs \\ %{}), do: StateReconciliation.reconcile(attrs)
  def verification_gate(attrs \\ %{}), do: VerificationGateway.evaluate(attrs)
  def continuation_packet(attrs \\ %{}), do: ContinuationPacket.build(attrs)
  def provider_profile(model_id, attrs \\ %{}), do: ProviderRegistry.profile(model_id, attrs)
  def verification_contract(attrs \\ %{}), do: VerificationContract.build(attrs)
  def evidence_contract(attrs \\ %{}), do: EvidenceContract.build(attrs)
  def evidence_contract_evaluation(attrs \\ %{}), do: EvidenceContract.evaluate(attrs)
  def safety_policy(attrs \\ %{}), do: SafetyPolicy.build(attrs)
  def recovery_contract(attrs \\ %{}), do: RecoveryContract.build(attrs)
  def run_debugger(attrs \\ %{}), do: RunDebugger.build(attrs)
  def meta_learning_snapshot(attrs \\ %{}), do: MetaLearningLoop.build(attrs)
  def format_local_model_result(result), do: OutputSanitizer.format_local_model_result(result)
  def redact_internal_payload_text(text), do: OutputSanitizer.redact_internal_payload_text(text)
  def agent_run_lifecycle_states, do: AgentRunStateMachine.states()

  def agent_run_lifecycle_transition(current_state, next_state),
    do: AgentRunStateMachine.transition(current_state, next_state)

  def agent_run_lifecycle_complete(attrs \\ %{}), do: AgentRunStateMachine.complete(attrs)
  def agent_loop_contract(attrs \\ %{}), do: AgentLoop.contract(attrs)

  def record_process_started(payload, context \\ %{}, opts \\ []),
    do: ProcessWakeScheduler.record_started(payload, context, opts)

  def notify_process_terminal(payload, context \\ %{}, opts \\ []),
    do: ProcessWakeScheduler.notify_terminal(payload, context, opts)

  def team_orchestration(attrs \\ %{}), do: TeamOrchestration.plan(attrs)
  def work_graph_budget(attrs \\ %{}), do: WorkGraphBudget.build(attrs)
  def work_graph(attrs \\ %{}), do: WorkGraph.build(attrs)
  def work_graph_gate(attrs \\ %{}), do: WorkGraph.completion_gate(attrs)
  def agent_dispatch(attrs \\ %{}), do: AgentDispatch.plan(attrs)

  def dispatch_selected_agent_ids(dispatch_plan),
    do: AgentDispatch.selected_agent_ids(dispatch_plan)

  def verifier_routing(attrs \\ %{}), do: VerifierRouting.plan(attrs)
  def verifier_assignment(attrs \\ %{}), do: VerifierAssignment.assign(attrs)
  def verifier_dispatch(attrs \\ %{}), do: VerifierDispatcher.build(attrs)
  def verifier_calibration(attrs \\ %{}), do: VerifierCalibration.build(attrs)
  def context_budget(attrs \\ %{}), do: ContextBudget.build(attrs)
  def context_budget_plan(attrs \\ %{}), do: ContextBudgetGovernor.plan(attrs)

  def compact_context_messages(messages, plan),
    do: ContextBudgetGovernor.compact_messages(messages, plan)

  def task_tool_session(attrs \\ %{}), do: TaskToolSession.build(attrs)
  def task_tool_session_prompt(session), do: TaskToolSession.prompt_section(session)
  def task_tool_route(attrs \\ %{}), do: TaskToolRouter.route(attrs)

  def task_tool_route(tool_name, arguments, session),
    do: TaskToolRouter.route(tool_name, arguments, session)

  def task_tool_allowed?(tool_name, session), do: TaskToolRouter.allowed?(tool_name, session)
  def verification_satisfied?(gate), do: VerificationGateway.satisfied?(gate)
  def verification_submitted?(%{"status" => "submitted"}), do: true
  def verification_submitted?(_gate), do: false

  def doctor(attrs \\ %{}) when is_map(attrs) do
    tools = tool_availability(attrs)
    status = if Enum.all?(tools, & &1["available"]), do: "ready", else: "degraded"

    %{
      "schema_version" => "holtworks_agent_runtime_doctor/v1",
      "status" => status,
      "tools" => tools
    }
  end

  def task_tool_session_for_task(ref_or_id, attrs \\ %{}, opts \\ []),
    do: Tasks.task_tool_session(ref_or_id, attrs, opts)
end
