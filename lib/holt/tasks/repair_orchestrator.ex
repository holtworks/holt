defmodule Holt.Tasks.RepairOrchestrator do
  @moduledoc """
  Converts completed action envelopes into bounded repair decisions.
  """

  alias Holt.Clock

  @schema_version "holt_repair_orchestration/v1"

  def orchestrate(attrs \\ %{})

  def orchestrate(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> orchestrate_canonical(input)
      {:error, reason} -> rejected_orchestration(attrs, reason)
    end
  end

  def orchestrate(_attrs), do: rejected_orchestration(%{}, "invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, envelope} <- runtime_envelope(attrs),
         {:ok, repair_attempt} <- optional_nonnegative_integer(attrs, "repair_attempt"),
         {:ok, max_repair_attempts} <- optional_positive_integer(attrs, "max_repair_attempts") do
      {:ok,
       %{
         envelope: envelope,
         repair_attempt: repair_attempt,
         max_repair_attempts: max_repair_attempts
       }}
    end
  end

  defp orchestrate_canonical(input) do
    envelope = input.envelope
    directive = envelope["repair_directive"]
    contract = envelope["action_contract"]
    mode = repair_mode(directive)
    budget = retry_budget(input, contract, mode)
    repair_plan = repair_plan(envelope, contract, mode, directive, budget)
    resume_gate = resume_gate(mode, budget, repair_plan)
    status = orchestration_status(mode, budget, resume_gate)

    %{
      "schema_version" => @schema_version,
      "repair_id" =>
        stable_id("repair", [
          envelope["envelope_id"],
          directive,
          mode,
          budget["attempts_used"]
        ]),
      "source_envelope_id" => envelope["envelope_id"],
      "source_action" => envelope["action"],
      "source_action_call_id" => envelope["action_call_id"],
      "directive" => directive,
      "mode" => mode,
      "status" => status,
      "repair_required" => mode != "none",
      "retry_budget" => budget,
      "repair_plan" => repair_plan,
      "resume_gate" => resume_gate,
      "memory_feedback" => memory_feedback(mode, status, envelope, repair_plan),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_orchestration(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "repair_id" =>
        output_text(
          attrs,
          "repair_id",
          stable_id("repair", [reason, attrs])
        ),
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp runtime_envelope(attrs) do
    case Map.fetch(attrs, "action_runtime_envelope") do
      {:ok, envelope} when is_map(envelope) ->
        with :ok <- validate_runtime_envelope(envelope) do
          {:ok, envelope}
        end

      {:ok, _envelope} ->
        {:error, "invalid_action_runtime_envelope"}

      :error ->
        {:error, "invalid_action_runtime_envelope"}
    end
  end

  defp validate_runtime_envelope(envelope) do
    with {:ok, _envelope_id} <-
           required_text(envelope, "envelope_id", "invalid_action_runtime_envelope"),
         {:ok, directive} <-
           required_text(envelope, "repair_directive", "invalid_action_runtime_envelope"),
         :ok <- repair_directive(directive),
         :ok <- optional_text_field(envelope, "action", "invalid_action_runtime_envelope"),
         :ok <- optional_text_field(envelope, "action_call_id", "invalid_action_runtime_envelope"),
         :ok <- required_map(envelope, "action_contract", "invalid_action_runtime_envelope"),
         :ok <-
           optional_map_field(envelope, "prediction_error", "invalid_action_runtime_envelope"),
         :ok <-
           optional_map_field(envelope, "state_reconciliation", "invalid_action_runtime_envelope"),
         :ok <- validate_action_contract(envelope["action_contract"]) do
      :ok
    end
  end

  defp validate_action_contract(contract) do
    with {:ok, _contract_id} <-
           required_text(contract, "contract_id", "invalid_action_runtime_envelope"),
         {:ok, _action} <- required_text(contract, "action", "invalid_action_runtime_envelope"),
         {:ok, _effect_scope} <-
           required_text(contract, "effect_scope", "invalid_action_runtime_envelope"),
         :ok <- optional_text_field(contract, "target_domain", "invalid_action_runtime_envelope"),
         :ok <- optional_text_field(contract, "risk_level", "invalid_action_runtime_envelope") do
      :ok
    end
  end

  defp repair_directive("continue"), do: :ok
  defp repair_directive("execute_then_reconcile"), do: :ok
  defp repair_directive("await_human_approval"), do: :ok
  defp repair_directive("wait_for_async_state_observation"), do: :ok
  defp repair_directive("enter_repair_phase_with_observed_error"), do: :ok
  defp repair_directive("enter_repair_phase_with_missing_state_delta"), do: :ok
  defp repair_directive("verify_unexpected_state_delta_before_continuing"), do: :ok
  defp repair_directive("enter_repair_phase_with_new_prediction"), do: :ok
  defp repair_directive("do_not_execute_replan"), do: :ok
  defp repair_directive(_directive), do: {:error, "invalid_repair_directive"}

  defp repair_mode("continue"), do: "none"
  defp repair_mode("execute_then_reconcile"), do: "none"
  defp repair_mode("await_human_approval"), do: "approval_wait"
  defp repair_mode("wait_for_async_state_observation"), do: "async_wait"
  defp repair_mode("enter_repair_phase_with_observed_error"), do: "repair_observed_error"

  defp repair_mode("enter_repair_phase_with_missing_state_delta"),
    do: "repair_missing_state_delta"

  defp repair_mode("verify_unexpected_state_delta_before_continuing"),
    do: "verify_unexpected_state_delta"

  defp repair_mode("enter_repair_phase_with_new_prediction"), do: "replan_with_new_prediction"
  defp repair_mode("do_not_execute_replan"), do: "replan_before_execution"

  defp retry_budget(input, contract, mode) do
    attempts_used = integer_default(input.repair_attempt, 0)
    max_attempts = max_attempts(input.max_repair_attempts, contract, mode)
    remaining = max(max_attempts - attempts_used, 0)

    %{
      "attempts_used" => attempts_used,
      "max_attempts" => max_attempts,
      "attempts_remaining" => remaining,
      "exhausted" => remaining <= 0 and mode not in ["none", "async_wait", "approval_wait"],
      "escalation" => escalation(mode, remaining)
    }
  end

  defp max_attempts(_explicit, _contract, mode)
       when mode in ["none", "async_wait", "approval_wait"],
       do: 0

  defp max_attempts(explicit, _contract, _mode) when is_integer(explicit), do: explicit
  defp max_attempts(_explicit, %{"risk_level" => "high"}, _mode), do: 1
  defp max_attempts(_explicit, _contract, _mode), do: 2

  defp escalation("none", _remaining), do: "none"
  defp escalation("async_wait", _remaining), do: "wait_for_observation"
  defp escalation("approval_wait", _remaining), do: "human_approval_required"
  defp escalation(_mode, remaining) when remaining <= 0, do: "human_review_required"
  defp escalation(_mode, _remaining), do: "retry_with_revised_state_model"

  defp repair_plan(_envelope, _contract, "none", _directive, _budget), do: nil
  defp repair_plan(_envelope, _contract, "async_wait", _directive, _budget), do: nil
  defp repair_plan(_envelope, _contract, "approval_wait", _directive, _budget), do: nil

  defp repair_plan(envelope, contract, mode, directive, budget) do
    error = optional_map_value(envelope, "prediction_error")
    reconciliation = optional_map_value(envelope, "state_reconciliation")

    plan =
      %{
        "schema_version" => "holt_repair_plan/v1",
        "mode" => mode,
        "directive" => directive,
        "source_envelope_id" => envelope["envelope_id"],
        "source_contract_id" => contract["contract_id"],
        "source_action" => contract["action"],
        "effect_scope" => contract["effect_scope"],
        "target_domain" => contract["target_domain"],
        "root_cause" => %{
          "prediction_matched" => error["matched"],
          "expected_result_status" => error["expected_result_status"],
          "actual_result_status" => error["actual_result_status"],
          "state_matched" => reconciliation["matched"],
          "state_delta_accuracy" => reconciliation["state_delta_accuracy"]
        },
        "missing_changes" => list_field(reconciliation, "missing_changes"),
        "unexpected_changes" => list_field(reconciliation, "unexpected_changes"),
        "retry_budget" => budget,
        "steps" => repair_steps(mode),
        "required_evidence" => required_evidence(mode)
      }
      |> compact()

    Map.put(plan, "repair_plan_id", stable_id("repair_plan", [plan]))
  end

  defp repair_steps("repair_observed_error"),
    do: [
      "reload_current_state",
      "fix_precondition_gap",
      "rerun_with_revised_prediction",
      "verify_repaired_state"
    ]

  defp repair_steps("repair_missing_state_delta"),
    do: [
      "reload_current_state",
      "apply_missing_delta",
      "compare_observed_delta",
      "resume_after_reconciliation"
    ]

  defp repair_steps("verify_unexpected_state_delta"),
    do: [
      "stop_additional_mutation",
      "verify_unexpected_delta",
      "record_rollback_or_acceptance",
      "resume_after_verifier_approval"
    ]

  defp repair_steps("replan_before_execution"),
    do: ["do_not_execute_rejected_action", "revise_plan_or_target", "build_new_action_envelope"]

  defp repair_steps(_mode),
    do: [
      "reload_current_state",
      "revise_prediction",
      "execute_bounded_repair",
      "verify_repaired_state"
    ]

  defp required_evidence("verify_unexpected_state_delta"),
    do: ["unexpected_delta_verification", "rollback_or_acceptance_decision"]

  defp required_evidence(_mode), do: ["state_reconciliation_passed"]

  defp resume_gate("none", _budget, _plan) do
    %{"status" => "satisfied", "can_resume" => true, "reason" => "no_repair_required"}
  end

  defp resume_gate("async_wait", _budget, _plan) do
    %{
      "status" => "waiting",
      "can_resume" => false,
      "reason" => "waiting_for_async_state_observation"
    }
  end

  defp resume_gate("approval_wait", _budget, _plan) do
    %{"status" => "waiting", "can_resume" => false, "reason" => "waiting_for_human_approval"}
  end

  defp resume_gate(_mode, %{"exhausted" => true}, _plan) do
    %{"status" => "blocked", "can_resume" => false, "reason" => "repair_retry_budget_exhausted"}
  end

  defp resume_gate(_mode, _budget, plan) do
    %{
      "status" => "open",
      "can_resume" => false,
      "reason" => "repair_must_complete_before_resume",
      "required_evidence" => plan_required_evidence(plan)
    }
  end

  defp orchestration_status("none", _budget, _gate), do: "not_required"
  defp orchestration_status("async_wait", _budget, _gate), do: "waiting"
  defp orchestration_status("approval_wait", _budget, _gate), do: "waiting"
  defp orchestration_status(_mode, %{"exhausted" => true}, _gate), do: "escalation_required"
  defp orchestration_status(_mode, _budget, %{"status" => "open"}), do: "repair_required"
  defp orchestration_status(_mode, _budget, _gate), do: "repair_pending"

  defp memory_feedback(mode, status, envelope, plan) do
    %{
      "feedback_kind" => "repair_effectiveness_seed",
      "source_envelope_id" => envelope["envelope_id"],
      "repair_plan_id" => repair_plan_id(plan),
      "mode" => mode,
      "status" => status,
      "effectiveness_status" => effectiveness_status(mode, status)
    }
    |> compact()
  end

  defp effectiveness_status("none", _status), do: "not_required"
  defp effectiveness_status(_mode, "repair_required"), do: "pending_repair"
  defp effectiveness_status(_mode, "waiting"), do: "pending_external_input"
  defp effectiveness_status(_mode, "escalation_required"), do: "escalated"
  defp effectiveness_status(_mode, _status), do: "pending"

  defp plan_required_evidence(%{"required_evidence" => evidence}) when is_list(evidence),
    do: evidence

  defp plan_required_evidence(_plan), do: []

  defp repair_plan_id(%{"repair_plan_id" => repair_plan_id}) when is_binary(repair_plan_id),
    do: repair_plan_id

  defp repair_plan_id(_plan), do: nil

  defp list_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> value
      _value -> []
    end
  end

  defp canonical_attrs(attrs) do
    case canonical_value?(attrs) do
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

  defp unsupported_arguments(attrs) do
    cond do
      Map.has_key?(attrs, "envelope") -> {:error, "unsupported_argument:envelope"}
      Map.has_key?(attrs, "repair_directive") -> {:error, "unsupported_argument:repair_directive"}
      true -> :ok
    end
  end

  defp required_map(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> value
      _missing -> %{}
    end
  end

  defp optional_map_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp optional_nonnegative_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_" <> key}
      :error -> {:ok, nil}
    end
  end

  defp optional_positive_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_" <> key}
      :error -> {:ok, nil}
    end
  end

  defp integer_default(nil, default), do: default
  defp integer_default(value, _default), do: value

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

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          _text -> :ok
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp output_text(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> text_default(trim_empty(value), default)
      _missing -> default
    end
  end

  defp output_text(_map, _key, default), do: default

  defp text_default(nil, default), do: default
  defp text_default(value, _default), do: value

  defp trim_empty(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
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
