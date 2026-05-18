defmodule Holt.Tasks.ActionRuntimeEnvelopeTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ActionRuntimeEnvelope

  describe "propose/1" do
    test "builds from canonical consequence gate contract fields" do
      envelope =
        ActionRuntimeEnvelope.propose(%{
          "action" => "legacy-action",
          "action_call_id" => "legacy-call",
          "consequence_gate" => consequence_gate()
        })

      assert envelope["schema_version"] == "holt_action_runtime_envelope/v1"
      assert envelope["execution_decision"] == "execute"
      assert envelope["action"] == "write"
      assert envelope["action_call_id"] == "call-1"
      assert envelope["action_contract"]["contract_id"] == "contract-1"
    end

    test "rejects attr action identity plus atom-keyed gates" do
      missing_action_gate =
        put_in(consequence_gate(), ["action_contract", "action"], nil)

      envelope =
        ActionRuntimeEnvelope.propose(%{
          "action" => "write",
          "action_call_id" => "call-from-attrs",
          "consequence_gate" => missing_action_gate
        })

      assert envelope["execution_decision"] == "reject"
      assert envelope["reason"] == "invalid_consequence_gate"
      refute Map.has_key?(envelope, "action")

      atom_gate =
        ActionRuntimeEnvelope.propose(%{
          "consequence_gate" => %{
            action: "approved",
            action_contract: %{"contract_id" => "contract-1", "action" => "write"}
          }
        })

      assert atom_gate["execution_decision"] == "reject"
      assert atom_gate["reason"] == "invalid_attrs"
      refute atom_gate["action"] == "write"
    end

    test "rejects invalid provided consequence gate instead of recomputing" do
      envelope =
        ActionRuntimeEnvelope.propose(%{
          "action_route" => %{"status" => "accepted"},
          "action_contract" => %{
            "contract_id" => "contract-1",
            "action" => "write",
            "effect_scope" => "workspace_durable"
          },
          "consequence_gate" => Map.delete(consequence_gate(), "prediction")
        })

      assert envelope["execution_decision"] == "reject"
      assert envelope["reason"] == "invalid_consequence_gate"
      refute Map.has_key?(envelope, "consequence_gate")
    end
  end

  describe "complete/2" do
    test "uses canonical completion contracts" do
      envelope = ActionRuntimeEnvelope.propose(%{"consequence_gate" => consequence_gate()})

      completed =
        ActionRuntimeEnvelope.complete(envelope, %{
          "execution_observation" => %{"status" => "completed"},
          "prediction_error" => %{"matched" => true},
          "state_reconciliation" => %{"matched" => true},
          "outcome_calibration" => %{"recovery_recommendation" => "none"},
          "repair_orchestration" => %{"status" => "not_required"}
        })

      assert completed["phase"] == "completed"
      assert completed["runtime_status"] == "completed_continue"
      assert completed["repair_directive"] == "continue"
      assert completed["repair_orchestration"]["status"] == "not_required"
    end

    test "rejects atom-keyed completion attrs" do
      envelope = ActionRuntimeEnvelope.propose(%{"consequence_gate" => consequence_gate()})

      completed =
        ActionRuntimeEnvelope.complete(envelope, %{
          execution_observation: %{"status" => "completed"}
        })

      assert completed["phase"] == "completed"
      assert completed["runtime_status"] == "completion_rejected"
      assert completed["reason"] == "invalid_attrs"
    end
  end

  defp consequence_gate do
    %{
      "gate_id" => "gate-1",
      "action" => "approved",
      "plan_contract" => %{"plan_id" => "plan-1"},
      "plan_gate" => %{"gate_id" => "plan-gate-1", "action" => "approved"},
      "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"},
      "policy_decision" => %{"decision_id" => "policy-1", "action" => "approved"},
      "action_contract" => %{
        "contract_id" => "contract-1",
        "action" => "write",
        "action_call_id" => "call-1",
        "effect_scope" => "workspace_durable",
        "risk_level" => "high",
        "target_domain" => "workspace"
      },
      "prediction" => %{"prediction_id" => "prediction-1"},
      "state_snapshot" => %{"snapshot_id" => "snapshot-1"},
      "state_transition_prediction" => %{"transition_id" => "transition-1"},
      "state_invariant_check" => %{"check_id" => "check-1"}
    }
  end
end
