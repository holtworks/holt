defmodule Holt.Tasks.RepairOrchestratorTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.RepairOrchestrator

  test "repair orchestration uses canonical runtime envelope" do
    repair =
      RepairOrchestrator.orchestrate(%{
        "action_runtime_envelope" => envelope(),
        "repair_attempt" => 1,
        "max_repair_attempts" => 3
      })

    assert repair["source_envelope_id"] == "env-1"
    assert repair["directive"] == "enter_repair_phase_with_missing_state_delta"
    assert repair["mode"] == "repair_missing_state_delta"
    assert repair["status"] == "repair_required"
    assert repair["retry_budget"]["attempts_used"] == 1
    assert repair["retry_budget"]["max_attempts"] == 3
    assert repair["resume_gate"]["required_evidence"] == ["state_reconciliation_passed"]
  end

  test "repair orchestration rejects legacy envelope and directive arguments" do
    assert %{"status" => "rejected", "reason" => "unsupported_argument:envelope"} =
             RepairOrchestrator.orchestrate(%{"envelope" => envelope()})

    assert %{"status" => "rejected", "reason" => "unsupported_argument:repair_directive"} =
             RepairOrchestrator.orchestrate(%{
               "action_runtime_envelope" => envelope(),
               "repair_directive" => "continue"
             })
  end

  test "repair orchestration does not recover repair attempts from the envelope" do
    repair =
      RepairOrchestrator.orchestrate(%{
        "action_runtime_envelope" => Map.put(envelope(), "repair_attempt", 4),
        "max_repair_attempts" => 3
      })

    assert repair["retry_budget"]["attempts_used"] == 0
  end

  test "repair orchestration rejects malformed envelopes and string budgets" do
    assert %{"status" => "rejected", "reason" => "invalid_attrs"} =
             RepairOrchestrator.orchestrate(%{
               "action_runtime_envelope" => %{
                 envelope_id: "env-1",
                 repair_directive: "enter_repair_phase_with_missing_state_delta"
               }
             })

    assert %{"status" => "rejected", "reason" => "invalid_repair_attempt"} =
             RepairOrchestrator.orchestrate(%{
               "action_runtime_envelope" => envelope(),
               "repair_attempt" => "2"
             })

    assert %{"status" => "rejected", "reason" => "invalid_max_repair_attempts"} =
             RepairOrchestrator.orchestrate(%{
               "action_runtime_envelope" => envelope(),
               "max_repair_attempts" => "5"
             })
  end

  test "repair orchestration requires explicit valid envelope directive" do
    assert %{"status" => "rejected", "reason" => "invalid_action_runtime_envelope"} =
             RepairOrchestrator.orchestrate(%{
               "action_runtime_envelope" => Map.delete(envelope(), "repair_directive")
             })

    assert %{"status" => "rejected", "reason" => "invalid_repair_directive"} =
             RepairOrchestrator.orchestrate(%{
               "action_runtime_envelope" =>
                 Map.put(envelope(), "repair_directive", "try_something")
             })
  end

  defp envelope do
    %{
      "envelope_id" => "env-1",
      "action" => "write",
      "action_call_id" => "call-1",
      "repair_directive" => "enter_repair_phase_with_missing_state_delta",
      "action_contract" => %{
        "contract_id" => "contract-1",
        "action" => "write",
        "effect_scope" => "task_durable",
        "target_domain" => "task"
      },
      "prediction_error" => %{
        "matched" => true,
        "expected_result_status" => "ok",
        "actual_result_status" => "ok"
      },
      "state_reconciliation" => %{
        "matched" => false,
        "state_delta_accuracy" => 0.5,
        "missing_changes" => [%{"state_key" => "task:1"}],
        "unexpected_changes" => []
      }
    }
  end
end
