defmodule Holt.Tasks.ActionRuntimeEnvelope do
  @moduledoc """
  Full lifecycle envelope for one proposed task action.

  The envelope carries an action from proposal through gating, execution
  observation, reconciliation, calibration, and repair/continue decision.
  """

  alias Holt.Clock

  alias Holt.Tasks.{
    ConsequenceGate,
    ExecutionObservation,
    OutcomeCalibration,
    PredictionError,
    RepairOrchestrator,
    RuntimeContracts,
    StateReconciliation
  }

  @schema_version "holtworks_action_runtime_envelope/v1"

  def propose(attrs \\ %{})

  def propose(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    gate = consequence_gate(attrs)
    contract = RuntimeContracts.normalize_map(gate["action_contract"])
    prediction = RuntimeContracts.normalize_map(gate["prediction"])
    transition = RuntimeContracts.normalize_map(gate["state_transition_prediction"])
    invariant = RuntimeContracts.normalize_map(gate["state_invariant_check"])
    action = gate["action"] || "rejected"

    %{
      "schema_version" => @schema_version,
      "envelope_id" =>
        RuntimeContracts.stable_id("action_envelope", [
          contract["contract_id"],
          gate["gate_id"],
          transition["transition_id"],
          action
        ]),
      "phase" => "gated",
      "runtime_status" => runtime_status_for_action(action),
      "execution_decision" => execution_decision(action),
      "tool_name" => contract["tool_name"] || attrs["tool_name"],
      "tool_call_id" => contract["tool_call_id"] || attrs["tool_call_id"],
      "effect_scope" => contract["effect_scope"],
      "risk_level" => contract["risk_level"],
      "target_domain" => contract["target_domain"],
      "repair_directive" => repair_directive_for_action(action),
      "required_lifecycle" => required_lifecycle(action),
      "action_contract" => contract,
      "plan_contract" => gate["plan_contract"],
      "plan_gate" => gate["plan_gate"],
      "action_preflight" => gate["action_preflight"],
      "policy_decision" => gate["policy_decision"],
      "consequence_gate" => gate,
      "prediction" => prediction,
      "state_snapshot" => gate["state_snapshot"],
      "state_transition_prediction" => transition,
      "state_invariant_check" => invariant,
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def propose(_attrs), do: propose(%{})

  def route(attrs \\ %{}) do
    envelope = propose(attrs)

    case envelope["execution_decision"] do
      "execute" -> {:approved, envelope}
      "await_approval" -> {:approval_required, envelope}
      _decision -> {:rejected, envelope}
    end
  end

  def complete(envelope, attrs \\ %{})

  def complete(envelope, attrs) when is_map(envelope) and is_map(attrs) do
    envelope = RuntimeContracts.string_keys(envelope)
    attrs = RuntimeContracts.string_keys(attrs)
    contract = RuntimeContracts.normalize_map(envelope["action_contract"])
    prediction = RuntimeContracts.normalize_map(envelope["prediction"])
    transition = RuntimeContracts.normalize_map(envelope["state_transition_prediction"])
    snapshot = RuntimeContracts.normalize_map(envelope["state_snapshot"])

    observation =
      case RuntimeContracts.value(attrs, "execution_observation") do
        value when is_map(value) ->
          RuntimeContracts.string_keys(value)

        _missing ->
          ExecutionObservation.from_result(%{
            "contract" => contract,
            "prediction" => prediction,
            "state_transition_prediction" => transition,
            "after_state_snapshot" => attrs["after_state_snapshot"],
            "observed_state_changes" => attrs["observed_state_changes"],
            "result" => attrs["result"],
            "status" => attrs["status"],
            "result_status" => attrs["result_status"],
            "latency_ms" => attrs["latency_ms"]
          })
      end

    prediction_error =
      case RuntimeContracts.value(attrs, "prediction_error") do
        value when is_map(value) ->
          RuntimeContracts.string_keys(value)

        _missing ->
          PredictionError.compare(%{"prediction" => prediction, "observation" => observation})
      end

    reconciliation =
      case RuntimeContracts.value(attrs, "state_reconciliation") do
        value when is_map(value) ->
          RuntimeContracts.string_keys(value)

        _missing ->
          StateReconciliation.reconcile(%{
            "state_transition_prediction" => transition,
            "state_snapshot" => snapshot,
            "observation" => observation,
            "observed_changes" => attrs["observed_changes"]
          })
      end

    calibration =
      case RuntimeContracts.value(attrs, "outcome_calibration") do
        value when is_map(value) ->
          RuntimeContracts.string_keys(value)

        _missing ->
          OutcomeCalibration.build(%{
            "action_contract" => contract,
            "prediction" => prediction,
            "observation" => observation,
            "prediction_error" => prediction_error,
            "state_reconciliation" => reconciliation
          })
      end

    completed =
      envelope
      |> Map.merge(%{
        "phase" => "completed",
        "runtime_status" =>
          completed_runtime_status(observation, prediction_error, reconciliation),
        "execution_observation" => observation,
        "prediction_error" => prediction_error,
        "state_reconciliation" => reconciliation,
        "outcome_calibration" => calibration,
        "repair_directive" =>
          completed_repair_directive(prediction_error, reconciliation, calibration),
        "completed_at" => Clock.iso_now()
      })
      |> RuntimeContracts.reject_empty()

    repair =
      case RuntimeContracts.value(attrs, "repair_orchestration") do
        value when is_map(value) ->
          RuntimeContracts.string_keys(value)

        _missing ->
          RepairOrchestrator.orchestrate(%{
            "action_runtime_envelope" => completed,
            "repair_attempt" => attrs["repair_attempt"],
            "max_repair_attempts" => attrs["max_repair_attempts"]
          })
      end

    completed
    |> Map.put("repair_orchestration", repair)
    |> RuntimeContracts.reject_empty()
  end

  def complete(_envelope, attrs), do: complete(propose(%{}), attrs)

  defp consequence_gate(attrs) do
    case RuntimeContracts.value(attrs, "consequence_gate") do
      gate when is_map(gate) -> RuntimeContracts.string_keys(gate)
      _missing -> ConsequenceGate.evaluate(attrs)
    end
  end

  defp runtime_status_for_action("approved"), do: "ready_to_execute"
  defp runtime_status_for_action("approval_required"), do: "awaiting_approval"
  defp runtime_status_for_action(_action), do: "rejected_before_execution"

  defp execution_decision("approved"), do: "execute"
  defp execution_decision("approval_required"), do: "await_approval"
  defp execution_decision(_action), do: "reject"

  defp repair_directive_for_action("approved"), do: "execute_then_reconcile"
  defp repair_directive_for_action("approval_required"), do: "await_human_approval"
  defp repair_directive_for_action(_action), do: "do_not_execute_replan"

  defp required_lifecycle("approved") do
    ~w(propose gate execute observe reconcile calibrate repair_or_continue)
  end

  defp required_lifecycle("approval_required") do
    ~w(propose gate await_approval execute observe reconcile calibrate repair_or_continue)
  end

  defp required_lifecycle(_action), do: ~w(propose gate reject repair)

  defp completed_runtime_status(%{"status" => "await_process"}, _error, _reconciliation) do
    "awaiting_async_observation"
  end

  defp completed_runtime_status(_observation, %{"matched" => true}, %{"matched" => true}) do
    "completed_continue"
  end

  defp completed_runtime_status(_observation, _error, _reconciliation) do
    "completed_repair_required"
  end

  defp completed_repair_directive(_error, %{"repair_directive" => directive}, _calibration)
       when directive not in [nil, "", "continue"] do
    directive
  end

  defp completed_repair_directive(_error, _reconciliation, %{
         "recovery_recommendation" => recommendation
       })
       when recommendation not in [nil, "", "none"] do
    recommendation
  end

  defp completed_repair_directive(%{"matched" => true}, _reconciliation, _calibration),
    do: "continue"

  defp completed_repair_directive(_error, _reconciliation, _calibration),
    do: "enter_repair_phase_with_new_prediction"
end
