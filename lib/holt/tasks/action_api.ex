defmodule Holt.Tasks.ActionApi do
  @moduledoc """
  Public action and runtime metadata facade for task workflows.

  This keeps catalog/execution/runtime-helper delegation out of the task record
  store while preserving the stable `Holt.Tasks` API.
  """

  alias Holt.{Actions, ResearchClaims}

  alias Holt.Tasks.{
    ActionAvailability,
    AgentLoop,
    AgentRunStateMachine,
    ContextBudget,
    MetaLearningLoop,
    ProviderRegistry,
    RecoveryContract,
    RunDebugger,
    SafetyPolicy
  }

  def definitions(opts \\ []), do: Actions.definitions(opts)

  def catalog(context \\ %{}, opts \\ []), do: Actions.agent_action_catalog(context, opts)

  def agent_definitions(context \\ %{}, opts \\ []),
    do: Actions.agent_action_definitions(context, opts)

  def provider_metadata(context \\ %{}, opts \\ []),
    do: Actions.action_provider_metadata(context, opts)

  def provider_prompt_sections(context \\ %{}, opts \\ []),
    do: Actions.action_provider_prompt_sections(context, opts)

  def search(filters \\ %{}, opts \\ []) when is_map(filters), do: Actions.search(filters, opts)

  def get(name, opts \\ []), do: Actions.get(name, opts)

  def execute(name, args \\ %{}, opts \\ []) when is_map(args),
    do: Actions.execute(name, args, opts)

  def dispatch(name, args \\ %{}, context \\ %{}, opts \\ []) when is_map(args),
    do: Actions.dispatch_agent_action(name, args, context, opts)

  def execute_task(ref_or_id, action_name, args \\ %{}, opts \\ []) when is_map(args),
    do: Actions.execute_task_action(ref_or_id, action_name, args, opts)

  def execute_many(ref_or_id, calls, opts \\ []) when is_list(calls),
    do: Actions.execute_many(ref_or_id, calls, opts)

  def availability(attrs \\ %{}) when is_map(attrs), do: ActionAvailability.snapshot(attrs)

  def provider_profile(model_id, attrs \\ %{}) when is_map(attrs),
    do: ProviderRegistry.profile(model_id, attrs)

  def research_claims(opts \\ []), do: ResearchClaims.list(opts)

  def safety_policy(attrs \\ %{}) when is_map(attrs), do: SafetyPolicy.build(attrs)

  def context_budget(attrs \\ %{}) when is_map(attrs), do: ContextBudget.build(attrs)

  def recovery_contract(attrs \\ %{}) when is_map(attrs), do: RecoveryContract.build(attrs)

  def run_debugger(attrs \\ %{}) when is_map(attrs), do: RunDebugger.build(attrs)

  def meta_learning_snapshot(attrs \\ %{}) when is_map(attrs), do: MetaLearningLoop.build(attrs)

  def lifecycle_states, do: AgentRunStateMachine.states()

  def lifecycle_transition(current_state, next_state),
    do: AgentRunStateMachine.transition(current_state, next_state)

  def lifecycle_complete(attrs \\ %{}) when is_map(attrs),
    do: AgentRunStateMachine.complete(attrs)

  def agent_loop_contract(attrs \\ %{}) when is_map(attrs), do: AgentLoop.contract(attrs)

  def doctor(attrs \\ %{}) when is_map(attrs) do
    actions = availability(attrs)
    status = if Enum.all?(actions, & &1["available"]), do: "ready", else: "degraded"

    %{
      "schema_version" => "holt_agent_runtime_doctor/v1",
      "status" => status,
      "actions" => actions
    }
  end
end
