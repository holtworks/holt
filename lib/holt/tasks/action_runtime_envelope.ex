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
    StateReconciliation
  }

  @schema_version "holt_action_runtime_envelope/v1"

  def propose(attrs \\ %{})

  def propose(attrs) when is_map(attrs) do
    case proposal_gate(attrs) do
      {:ok, gate} -> envelope_from_gate(gate)
      {:error, reason} -> rejected_envelope(attrs, reason)
    end
  end

  def propose(_attrs), do: rejected_envelope(%{}, "invalid_attrs")

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
    case completion_input(envelope, attrs) do
      {:ok, canonical_envelope, canonical_attrs} ->
        complete_canonical(canonical_envelope, canonical_attrs)

      {:error, reason} ->
        rejected_completion(envelope, reason)
    end
  end

  def complete(_envelope, _attrs), do: rejected_completion(%{}, "invalid_attrs")

  defp proposal_gate(attrs) do
    with :ok <- canonical_attrs(attrs) do
      case Map.fetch(attrs, "consequence_gate") do
        {:ok, gate} when is_map(gate) ->
          with :ok <- validate_consequence_gate(gate) do
            {:ok, gate}
          end

        {:ok, _gate} ->
          {:error, "invalid_consequence_gate"}

        :error ->
          {:ok, ConsequenceGate.evaluate(attrs)}
      end
    end
  end

  defp envelope_from_gate(gate) do
    action = gate_action(gate)
    contract = optional_map_value(gate, "action_contract")
    prediction = optional_map_value(gate, "prediction")
    transition = optional_map_value(gate, "state_transition_prediction")
    invariant = optional_map_value(gate, "state_invariant_check")

    %{
      "schema_version" => @schema_version,
      "envelope_id" =>
        stable_id("action_envelope", [
          contract["contract_id"],
          gate["gate_id"],
          transition["transition_id"],
          action
        ]),
      "phase" => "gated",
      "runtime_status" => runtime_status_for_action(action),
      "execution_decision" => execution_decision(action),
      "action" => contract["action"],
      "action_call_id" => contract["action_call_id"],
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
    |> compact()
  end

  defp rejected_envelope(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "envelope_id" =>
        output_text(
          attrs,
          "envelope_id",
          stable_id("action_envelope", [reason, attrs])
        ),
      "phase" => "gated",
      "runtime_status" => "rejected_before_execution",
      "execution_decision" => "reject",
      "reason" => reason,
      "repair_directive" => "do_not_execute_replan",
      "required_lifecycle" => required_lifecycle("rejected"),
      "created_at" => Clock.iso_now()
    }
  end

  defp gate_action(gate) do
    case text_field(gate, "action") do
      nil -> "rejected"
      action -> action
    end
  end

  defp completion_input(envelope, attrs) do
    with :ok <- canonical_attrs(envelope),
         :ok <- canonical_attrs(attrs),
         :ok <- validate_runtime_envelope(envelope),
         :ok <- validate_completion_attrs(attrs) do
      {:ok, envelope, attrs}
    end
  end

  defp complete_canonical(envelope, attrs) do
    contract = optional_map_value(envelope, "action_contract")
    prediction = optional_map_value(envelope, "prediction")
    transition = optional_map_value(envelope, "state_transition_prediction")

    observation = execution_observation(attrs, contract, prediction, transition)
    prediction_error = prediction_error(attrs, prediction, observation)
    reconciliation = state_reconciliation(attrs, transition, observation)

    calibration =
      outcome_calibration(
        attrs,
        contract,
        prediction,
        observation,
        prediction_error,
        reconciliation
      )

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
      |> compact()

    completed
    |> Map.put("repair_orchestration", repair_orchestration(attrs, completed))
    |> compact()
  end

  defp rejected_completion(envelope, reason) do
    envelope =
      case canonical_value?(envelope) do
        true -> envelope
        false -> %{}
      end

    envelope
    |> Map.merge(%{
      "schema_version" => @schema_version,
      "phase" => "completed",
      "runtime_status" => "completion_rejected",
      "repair_directive" => "enter_repair_phase_with_new_prediction",
      "reason" => reason,
      "completed_at" => Clock.iso_now()
    })
    |> compact()
  end

  defp execution_observation(attrs, contract, prediction, transition) do
    case Map.fetch(attrs, "execution_observation") do
      {:ok, observation} when is_map(observation) ->
        observation

      :error ->
        %{
          "action_contract" => contract,
          "prediction" => prediction,
          "state_transition_prediction" => transition
        }
        |> put_optional_attr(attrs, "after_state_snapshot")
        |> put_optional_attr(attrs, "observed_state_changes")
        |> put_optional_attr(attrs, "result")
        |> put_optional_attr(attrs, "result_status")
        |> put_optional_attr(attrs, "latency_ms")
        |> ExecutionObservation.from_result()
    end
  end

  defp prediction_error(attrs, prediction, observation) do
    case Map.fetch(attrs, "prediction_error") do
      {:ok, error} when is_map(error) ->
        error

      :error ->
        PredictionError.compare(%{"prediction" => prediction, "observation" => observation})
    end
  end

  defp state_reconciliation(attrs, transition, observation) do
    case Map.fetch(attrs, "state_reconciliation") do
      {:ok, reconciliation} when is_map(reconciliation) ->
        reconciliation

      :error ->
        StateReconciliation.reconcile(%{
          "state_transition_prediction" => transition,
          "observation" => observation
        })
    end
  end

  defp outcome_calibration(
         attrs,
         contract,
         prediction,
         observation,
         prediction_error,
         reconciliation
       ) do
    case Map.fetch(attrs, "outcome_calibration") do
      {:ok, calibration} when is_map(calibration) ->
        calibration

      :error ->
        OutcomeCalibration.build(%{
          "action_contract" => contract,
          "prediction" => prediction,
          "observation" => observation,
          "prediction_error" => prediction_error,
          "state_reconciliation" => reconciliation
        })
    end
  end

  defp repair_orchestration(attrs, completed) do
    case Map.fetch(attrs, "repair_orchestration") do
      {:ok, repair} when is_map(repair) ->
        repair

      :error ->
        %{"action_runtime_envelope" => completed}
        |> put_present("repair_attempt", attrs["repair_attempt"])
        |> put_present("max_repair_attempts", attrs["max_repair_attempts"])
        |> RepairOrchestrator.orchestrate()
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

  defp validate_consequence_gate(gate) do
    with {:ok, _gate_id} <- required_text(gate, "gate_id", "invalid_consequence_gate"),
         {:ok, action} <- required_text(gate, "action", "invalid_consequence_gate"),
         :ok <- gate_action_value(action),
         :ok <- required_gate_contracts(action, gate) do
      :ok
    end
  end

  defp gate_action_value("approved"), do: :ok
  defp gate_action_value("approval_required"), do: :ok
  defp gate_action_value("rejected"), do: :ok
  defp gate_action_value(_action), do: {:error, "invalid_consequence_gate"}

  defp required_gate_contracts(action, gate) when action in ["approved", "approval_required"] do
    with :ok <- required_map(gate, "action_contract", "invalid_consequence_gate"),
         :ok <- required_map(gate, "plan_contract", "invalid_consequence_gate"),
         :ok <- required_map(gate, "plan_gate", "invalid_consequence_gate"),
         :ok <- required_map(gate, "action_preflight", "invalid_consequence_gate"),
         :ok <- required_map(gate, "policy_decision", "invalid_consequence_gate"),
         :ok <- required_map(gate, "prediction", "invalid_consequence_gate"),
         :ok <- required_map(gate, "state_snapshot", "invalid_consequence_gate"),
         :ok <- required_map(gate, "state_transition_prediction", "invalid_consequence_gate"),
         :ok <- required_map(gate, "state_invariant_check", "invalid_consequence_gate") do
      validate_action_contract(gate["action_contract"])
    end
  end

  defp required_gate_contracts(_action, _gate), do: :ok

  defp validate_runtime_envelope(envelope) do
    with {:ok, _envelope_id} <- required_text(envelope, "envelope_id", "invalid_envelope"),
         {:ok, _phase} <- required_text(envelope, "phase", "invalid_envelope"),
         {:ok, decision} <- required_text(envelope, "execution_decision", "invalid_envelope"),
         :ok <- execution_decision_value(decision),
         :ok <- optional_map(envelope, "action_contract", "invalid_envelope"),
         :ok <- optional_map(envelope, "prediction", "invalid_envelope"),
         :ok <- optional_map(envelope, "state_transition_prediction", "invalid_envelope"),
         :ok <- optional_map(envelope, "state_snapshot", "invalid_envelope") do
      :ok
    end
  end

  defp execution_decision_value("execute"), do: :ok
  defp execution_decision_value("await_approval"), do: :ok
  defp execution_decision_value("reject"), do: :ok
  defp execution_decision_value(_decision), do: {:error, "invalid_envelope"}

  defp validate_completion_attrs(attrs) do
    with :ok <- optional_map(attrs, "execution_observation", "invalid_execution_observation"),
         :ok <- optional_map(attrs, "prediction_error", "invalid_prediction_error"),
         :ok <- optional_map(attrs, "state_reconciliation", "invalid_state_reconciliation"),
         :ok <- optional_map(attrs, "outcome_calibration", "invalid_outcome_calibration"),
         :ok <- optional_map(attrs, "repair_orchestration", "invalid_repair_orchestration") do
      :ok
    end
  end

  defp validate_action_contract(contract) do
    with {:ok, _contract_id} <- required_text(contract, "contract_id", "invalid_consequence_gate"),
         {:ok, _action} <- required_text(contract, "action", "invalid_consequence_gate"),
         {:ok, _effect_scope} <-
           required_text(contract, "effect_scope", "invalid_consequence_gate") do
      :ok
    end
  end

  defp canonical_attrs(value) do
    case canonical_value?(value) do
      true -> :ok
      false -> {:error, "invalid_attrs"}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp optional_map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> value
      _missing -> %{}
    end
  end

  defp required_map(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_map(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp required_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:error, reason}
    end
  end

  defp text_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> trim_empty(value)
      _missing -> nil
    end
  end

  defp text_field(_map, _key), do: nil

  defp output_text(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> text_default(trim_empty(value), default)
      _missing -> default
    end
  end

  defp output_text(_map, _key, default), do: default

  defp text_default(nil, default), do: default
  defp text_default(value, _default), do: value

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_optional_attr(map, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(map, key, value)
      :error -> map
    end
  end

  defp trim_empty(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
