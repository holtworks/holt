defmodule Holt.Tasks.HumanApprovalInboxTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.HumanApprovalInbox

  test "approval requests use canonical action runtime envelope fields" do
    request =
      HumanApprovalInbox.build_request(%{
        "action_runtime_envelope" => envelope(),
        "force_approval_request" => true
      })

    assert request["status"] == "pending"
    assert request["source_envelope_id"] == "env-1"
    assert request["action"] == "write"
    assert request["effect_scope"] == "workspace_durable"
    assert request["target_domain"] == "workspace"
    assert request["risk_level"] == "high"
    assert request["reason"] == "policy_requires_approval"
    assert request["rollback_contract"] == %{"undoable" => true, "strategy" => "restore_file"}
  end

  test "approval requests reject legacy envelope argument" do
    assert %{"status" => "rejected", "reason" => "unsupported_argument:envelope"} =
             HumanApprovalInbox.build_request(%{"envelope" => envelope()})
  end

  test "approval requests require canonical envelopes and literal force approval" do
    assert %{"status" => "rejected", "reason" => "invalid_attrs"} =
             HumanApprovalInbox.build_request(%{
               "action_runtime_envelope" => %{
                 envelope_id: "env-1",
                 action_contract: %{"action" => "write"}
               },
               "force_approval_request" => true
             })

    assert %{"status" => "rejected", "reason" => "invalid_force_approval_request"} =
             HumanApprovalInbox.build_request(%{
               "action_runtime_envelope" => envelope(),
               "force_approval_request" => "true"
             })

    refute HumanApprovalInbox.build_request(%{
             "action_runtime_envelope" => auto_approval_envelope()
           })
  end

  test "approval resolutions accept only canonical decisions" do
    request = %{"approval_request_id" => "approval-1", "source_envelope_id" => "env-1"}

    assert %{"status" => "approved", "decision" => "approved"} =
             HumanApprovalInbox.resolve(request, %{"decision" => "approved"})

    assert %{"status" => "rejected", "decision" => "invalid", "reason" => "invalid_decision"} =
             HumanApprovalInbox.resolve(request, %{"decision" => "approve"})

    assert %{"status" => "rejected", "decision" => "invalid", "reason" => "invalid_decision"} =
             HumanApprovalInbox.resolve(request, %{"decision" => "denied"})

    assert %{"status" => "rejected", "decision" => "invalid", "reason" => "invalid_attrs"} =
             HumanApprovalInbox.resolve(request, %{decision: :approved})

    assert %{"status" => "pending", "decision" => "unresolved"} =
             HumanApprovalInbox.resolve(request, %{})
  end

  test "approval resolutions reject invalid requests" do
    assert %{"status" => "rejected", "reason" => "invalid_request"} =
             HumanApprovalInbox.resolve(%{"source_envelope_id" => "env-1"}, %{
               "decision" => "approved"
             })
  end

  defp envelope do
    %{
      "envelope_id" => "env-1",
      "action" => "legacy-action",
      "action_call_id" => "legacy-call",
      "execution_decision" => "await_approval",
      "action_contract" => %{
        "contract_id" => "contract-1",
        "action" => "write",
        "action_call_id" => "call-1",
        "effect_scope" => "workspace_durable",
        "target_domain" => "workspace",
        "risk_level" => "high",
        "target_refs" => %{"path" => "README.md"},
        "recovery" => %{"undoable" => true, "strategy" => "restore_file"},
        "capability_registry_entry" => %{
          "action_type" => "write",
          "effect_scope" => "legacy_scope",
          "target_domain" => "legacy_domain",
          "risk_level" => "low",
          "approval_policy" => %{
            "mode" => "human_required",
            "reason_code" => "capability_reason"
          },
          "rollback_contract" => %{"undoable" => false}
        }
      },
      "policy_decision" => %{
        "decision_id" => "decision-1",
        "action" => "approval_required",
        "reason" => "policy_requires_approval"
      },
      "prediction" => %{"prediction_id" => "prediction-1"}
    }
  end

  defp auto_approval_envelope do
    envelope()
    |> Map.put("execution_decision", "execute")
    |> Map.put("policy_decision", %{"decision_id" => "decision-1", "action" => "approved"})
    |> put_in(
      ["action_contract", "capability_registry_entry", "approval_policy"],
      %{"mode" => "auto"}
    )
  end
end
