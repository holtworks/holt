defmodule Holt.Tasks.RepairOrchestrator do
  @moduledoc """
  Converts completed action envelopes into bounded repair decisions.
  """

  alias Holt.Clock
  alias Holt.Tasks.RuntimeContracts

  @schema_version "holtworks_repair_orchestration/v1"

  def orchestrate(attrs \\ %{})

  def orchestrate(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    envelope =
      RuntimeContracts.normalize_map(
        RuntimeContracts.value(attrs, "action_runtime_envelope") ||
          RuntimeContracts.value(attrs, "envelope")
      )

    directive =
      RuntimeContracts.text(attrs, "repair_directive", envelope["repair_directive"] || "continue")

    contract = RuntimeContracts.normalize_map(envelope["action_contract"])
    mode = repair_mode(directive)
    budget = retry_budget(attrs, envelope, contract, mode)
    repair_plan = repair_plan(envelope, contract, mode, directive, budget)
    resume_gate = resume_gate(mode, budget, repair_plan)
    status = orchestration_status(mode, budget, resume_gate)

    %{
      "schema_version" => @schema_version,
      "repair_id" =>
        RuntimeContracts.stable_id("repair", [
          envelope["envelope_id"],
          directive,
          mode,
          budget["attempts_used"]
        ]),
      "source_envelope_id" => envelope["envelope_id"],
      "source_tool_name" => envelope["tool_name"],
      "source_tool_call_id" => envelope["tool_call_id"],
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
    |> RuntimeContracts.reject_empty()
  end

  def orchestrate(_attrs), do: orchestrate(%{})

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
  defp repair_mode(_directive), do: "generic_repair"

  defp retry_budget(attrs, envelope, contract, mode) do
    attempts_used =
      RuntimeContracts.integer(
        RuntimeContracts.value(attrs, "repair_attempt") || envelope["repair_attempt"] || 0
      )

    max_attempts = max_attempts(attrs, contract, mode)
    remaining = max(max_attempts - attempts_used, 0)

    %{
      "attempts_used" => attempts_used,
      "max_attempts" => max_attempts,
      "attempts_remaining" => remaining,
      "exhausted" => remaining <= 0 and mode not in ["none", "async_wait", "approval_wait"],
      "escalation" => escalation(mode, remaining)
    }
  end

  defp max_attempts(_attrs, _contract, mode) when mode in ["none", "async_wait", "approval_wait"],
    do: 0

  defp max_attempts(attrs, contract, _mode) do
    explicit = RuntimeContracts.integer(RuntimeContracts.value(attrs, "max_repair_attempts"))

    cond do
      explicit > 0 -> explicit
      contract["risk_level"] == "high" -> 1
      true -> 2
    end
  end

  defp escalation("none", _remaining), do: "none"
  defp escalation("async_wait", _remaining), do: "wait_for_observation"
  defp escalation("approval_wait", _remaining), do: "human_approval_required"
  defp escalation(_mode, remaining) when remaining <= 0, do: "human_review_required"
  defp escalation(_mode, _remaining), do: "retry_with_revised_state_model"

  defp repair_plan(_envelope, _contract, "none", _directive, _budget), do: nil
  defp repair_plan(_envelope, _contract, "async_wait", _directive, _budget), do: nil
  defp repair_plan(_envelope, _contract, "approval_wait", _directive, _budget), do: nil

  defp repair_plan(envelope, contract, mode, directive, budget) do
    error = RuntimeContracts.normalize_map(envelope["prediction_error"])
    reconciliation = RuntimeContracts.normalize_map(envelope["state_reconciliation"])

    plan =
      %{
        "schema_version" => "holtworks_repair_plan/v1",
        "mode" => mode,
        "directive" => directive,
        "source_envelope_id" => envelope["envelope_id"],
        "source_contract_id" => contract["contract_id"],
        "source_tool_name" => contract["tool_name"],
        "effect_scope" => contract["effect_scope"],
        "target_domain" => contract["target_domain"],
        "root_cause" => %{
          "prediction_matched" => error["matched"],
          "expected_result_status" => error["expected_result_status"],
          "actual_result_status" => error["actual_result_status"],
          "state_matched" => reconciliation["matched"],
          "state_delta_accuracy" => reconciliation["state_delta_accuracy"]
        },
        "missing_changes" => reconciliation["missing_changes"] || [],
        "unexpected_changes" => reconciliation["unexpected_changes"] || [],
        "retry_budget" => budget,
        "steps" => repair_steps(mode),
        "required_evidence" => required_evidence(mode)
      }
      |> RuntimeContracts.reject_empty()

    Map.put(plan, "repair_plan_id", RuntimeContracts.stable_id("repair_plan", [plan]))
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
      "required_evidence" => RuntimeContracts.value(plan || %{}, "required_evidence") || []
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
      "repair_plan_id" => RuntimeContracts.value(plan || %{}, "repair_plan_id"),
      "mode" => mode,
      "status" => status,
      "effectiveness_status" => effectiveness_status(mode, status)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp effectiveness_status("none", _status), do: "not_required"
  defp effectiveness_status(_mode, "repair_required"), do: "pending_repair"
  defp effectiveness_status(_mode, "waiting"), do: "pending_external_input"
  defp effectiveness_status(_mode, "escalation_required"), do: "escalated"
  defp effectiveness_status(_mode, _status), do: "pending"
end
