defmodule HoltWorks.Tasks.ConsequenceGate do
  @moduledoc """
  Pre-execution consequence gate for task-scoped tool actions.
  """

  alias HoltWorks.Clock

  alias HoltWorks.Tasks.{
    ActionContract,
    ActionPreflight,
    ConsequencePredictor,
    PlanContract,
    PlanGate,
    PolicyEngine,
    RuntimeContracts,
    StateInvariantCheck,
    StateTransitionPrediction,
    WorldStateSnapshot
  }

  @schema_version "holtworks_consequence_gate/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    context = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "context"))
    contract = action_contract(attrs)
    plan = plan_contract(attrs)
    plan_gate = plan_gate(attrs, plan, contract)
    preflight = action_preflight(attrs, plan, plan_gate, contract)

    policy =
      policy_decision(attrs, %{
        "context" => context,
        "plan_contract" => plan,
        "plan_gate" => plan_gate,
        "action_preflight" => preflight,
        "action_contract" => contract
      })

    prediction = consequence_prediction(attrs, contract, plan, plan_gate, preflight)
    snapshot = state_snapshot(attrs, context, contract, plan)
    transition = state_transition_prediction(attrs, contract, prediction, snapshot)
    invariant = state_invariant_check(attrs, context, contract, snapshot, transition)
    action = final_action(policy["action"], invariant["action"])

    %{
      "schema_version" => @schema_version,
      "gate_id" =>
        RuntimeContracts.stable_id("consequence_gate", [
          plan_gate["gate_id"],
          preflight["preflight_id"],
          contract["contract_id"],
          prediction["prediction_id"],
          invariant["check_id"]
        ]),
      "action" => action,
      "reason" => decision_reason(action, policy, invariant, contract),
      "enforced" => true,
      "policy" => "active_plan_policy_engine_consequence_contract_v1",
      "policy_decision" => policy,
      "plan_contract" => plan,
      "plan_gate" => plan_gate,
      "action_preflight" => preflight,
      "action_contract" => contract,
      "prediction" => prediction,
      "state_snapshot" => snapshot,
      "state_transition_prediction" => transition,
      "state_invariant_check" => invariant,
      "requires_observation" => action == "approved",
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def evaluate(_attrs), do: evaluate(%{})

  def route(attrs \\ %{}) do
    gate = evaluate(attrs)

    case gate["action"] do
      "approved" -> {:approved, gate}
      "approval_required" -> {:approval_required, gate}
      _action -> {:rejected, gate}
    end
  end

  defp action_contract(attrs) do
    case RuntimeContracts.value(attrs, "action_contract") ||
           RuntimeContracts.value(attrs, "contract") do
      contract when is_map(contract) -> RuntimeContracts.string_keys(contract)
      _missing -> ActionContract.build(attrs)
    end
  end

  defp plan_contract(attrs) do
    case RuntimeContracts.value(attrs, "plan_contract") do
      plan when is_map(plan) -> RuntimeContracts.string_keys(plan)
      _missing -> PlanContract.build(attrs)
    end
  end

  defp plan_gate(attrs, plan, contract) do
    case RuntimeContracts.value(attrs, "plan_gate") do
      gate when is_map(gate) ->
        RuntimeContracts.string_keys(gate)

      _missing ->
        PlanGate.evaluate(%{
          "plan_contract" => plan,
          "action_contract" => contract,
          "task_tool_route" =>
            RuntimeContracts.value(attrs, "task_tool_route") ||
              RuntimeContracts.value(attrs, "route")
        })
    end
  end

  defp action_preflight(attrs, plan, plan_gate, contract) do
    case RuntimeContracts.value(attrs, "action_preflight") do
      preflight when is_map(preflight) ->
        RuntimeContracts.string_keys(preflight)

      _missing ->
        ActionPreflight.evaluate(
          attrs
          |> Map.put("plan_contract", plan)
          |> Map.put("plan_gate", plan_gate)
          |> Map.put("action_contract", contract)
        )
    end
  end

  defp policy_decision(attrs, policy_attrs) do
    case RuntimeContracts.value(attrs, "policy_decision") do
      policy when is_map(policy) -> RuntimeContracts.string_keys(policy)
      _missing -> PolicyEngine.evaluate(policy_attrs)
    end
  end

  defp consequence_prediction(attrs, contract, plan, plan_gate, preflight) do
    cond do
      is_map(RuntimeContracts.value(attrs, "prediction")) ->
        RuntimeContracts.string_keys(RuntimeContracts.value(attrs, "prediction"))

      plan_gate["action"] == "approved" and preflight["result"] != "blocked" ->
        ConsequencePredictor.predict(%{
          "action_contract" => contract,
          "plan_contract" => plan,
          "action_preflight" => preflight
        })

      true ->
        %{}
    end
  end

  defp state_snapshot(attrs, context, contract, plan) do
    case RuntimeContracts.value(attrs, "state_snapshot") do
      snapshot when is_map(snapshot) ->
        RuntimeContracts.string_keys(snapshot)

      _missing ->
        WorldStateSnapshot.build(%{
          "context" => context,
          "action_contract" => contract,
          "plan_contract" => plan,
          "task" => RuntimeContracts.value(attrs, "task")
        })
    end
  end

  defp state_transition_prediction(attrs, contract, prediction, snapshot) do
    case RuntimeContracts.value(attrs, "state_transition_prediction") do
      transition when is_map(transition) ->
        RuntimeContracts.string_keys(transition)

      _missing ->
        if prediction == %{} do
          %{}
        else
          StateTransitionPrediction.predict(%{
            "action_contract" => contract,
            "prediction" => prediction,
            "state_snapshot" => snapshot
          })
        end
    end
  end

  defp state_invariant_check(attrs, context, contract, snapshot, transition) do
    case RuntimeContracts.value(attrs, "state_invariant_check") do
      invariant when is_map(invariant) ->
        RuntimeContracts.string_keys(invariant)

      _missing ->
        StateInvariantCheck.evaluate(%{
          "context" => context,
          "action_contract" => contract,
          "state_snapshot" => snapshot,
          "state_transition_prediction" => transition
        })
    end
  end

  defp final_action("rejected", _invariant_action), do: "rejected"
  defp final_action(_policy_action, "rejected"), do: "rejected"
  defp final_action("approval_required", _invariant_action), do: "approval_required"
  defp final_action(_policy_action, "approval_required"), do: "approval_required"
  defp final_action("approved", "approved"), do: "approved"
  defp final_action("approved", nil), do: "approved"
  defp final_action(_policy_action, _invariant_action), do: "rejected"

  defp decision_reason("approved", _policy, _invariant, contract) do
    "consequence_contract_approved:" <> to_string(contract["effect_scope"])
  end

  defp decision_reason("approval_required", policy, invariant, contract) do
    policy["reason"] || invariant["reason"] ||
      "human_approval_required_for:" <> to_string(contract["effect_scope"])
  end

  defp decision_reason(_action, policy, invariant, _contract) do
    policy["reason"] || invariant["reason"] || "consequence_gate_rejected"
  end
end
