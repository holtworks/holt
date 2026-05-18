defmodule Holt.Tasks.PolicyEngineTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.PolicyEngine

  test "approves canonical read-only action after plan and preflight pass" do
    decision =
      PolicyEngine.evaluate(%{
        "context" => %{"work_role" => "worker"},
        "action_contract" => action_contract("get_task", "read_only"),
        "plan_gate" => %{"gate_id" => "gate-1", "action" => "approved"},
        "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
      })

    assert decision["schema_version"] == "holt_policy_decision/v1"
    assert decision["action"] == "approved"
    assert decision["rule_id"] == "default_allow_after_contracts"
    assert decision["requires_approval"] == false
  end

  test "rejects canonical verifier mutating action" do
    decision =
      PolicyEngine.evaluate(%{
        "context" => %{"work_role" => "verifier"},
        "action_contract" => action_contract("write", "workspace_durable"),
        "plan_gate" => %{"gate_id" => "gate-1", "action" => "approved"},
        "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
      })

    assert decision["action"] == "rejected"
    assert decision["rule_id"] == "read_only_verifier_boundary"
    assert decision["reason"] == "read_only_verifier_cannot_mutate"
  end

  test "does not infer verifier context from non-canonical role fields" do
    decision =
      PolicyEngine.evaluate(%{
        "context" => %{"role" => "verifier", "agent_role" => "verifier"},
        "action_contract" => action_contract("write", "workspace_durable"),
        "plan_gate" => %{"gate_id" => "gate-1", "action" => "approved"},
        "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
      })

    assert decision["action"] == "approved"
    assert decision["rule_id"] == "default_allow_after_contracts"
  end

  test "requires literal verifier context boolean" do
    string_context =
      PolicyEngine.evaluate(%{
        "context" => %{"verifier_context" => "true"},
        "action_contract" => action_contract("write", "workspace_durable"),
        "plan_gate" => %{"gate_id" => "gate-1", "action" => "approved"},
        "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
      })

    literal_context =
      PolicyEngine.evaluate(%{
        "context" => %{"verifier_context" => true},
        "action_contract" => action_contract("write", "workspace_durable"),
        "plan_gate" => %{"gate_id" => "gate-1", "action" => "approved"},
        "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
      })

    assert string_context["action"] == "rejected"
    assert string_context["reason"] == "invalid_context"
    assert literal_context["action"] == "rejected"
    assert literal_context["rule_id"] == "read_only_verifier_boundary"
  end

  test "rejects atom-keyed attrs and nested contracts before policy rules" do
    assert %{
             "schema_version" => "holt_policy_decision/v1",
             "action" => "rejected",
             "reason" => "invalid_attrs",
             "rule_id" => "invalid_policy_attrs"
           } =
             PolicyEngine.evaluate(%{
               "context" => %{"work_role" => "worker"},
               "action_contract" => %{
                 contract_id: "contract-write",
                 action: "write",
                 effect_scope: "workspace_durable"
               },
               "plan_gate" => %{"gate_id" => "gate-1", "action" => "approved"},
               "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
             })

    assert %{
             "schema_version" => "holt_policy_decision/v1",
             "action" => "rejected",
             "reason" => "invalid_attrs",
             "rule_id" => "invalid_policy_attrs"
           } =
             PolicyEngine.evaluate(
               %{
                 "plan_gate" => %{"gate_id" => "gate-1", "action" => "approved"},
                 "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
               }
               |> Map.put(:action_contract, action_contract("write", "workspace_durable"))
             )
  end

  test "uses explicit plan gate reason defaults" do
    rejected =
      PolicyEngine.evaluate(%{
        "action_contract" => action_contract("get_task", "read_only"),
        "plan_gate" => %{"gate_id" => "gate-1", "action" => "rejected"},
        "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
      })

    approval_required =
      PolicyEngine.evaluate(%{
        "action_contract" => action_contract("get_task", "read_only"),
        "plan_gate" => %{"gate_id" => "gate-2", "action" => "approval_required"},
        "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
      })

    assert rejected["action"] == "rejected"
    assert rejected["reason"] == "plan_gate_rejected"
    assert approval_required["action"] == "approval_required"
    assert approval_required["reason"] == "plan_gate_requires_approval"
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_policy_decision/v1",
             "action" => "rejected",
             "reason" => "invalid_attrs",
             "rule_id" => "invalid_policy_attrs"
           } = PolicyEngine.evaluate([])
  end

  test "rejects invalid explicit policy contract fields" do
    assert %{
             "schema_version" => "holt_policy_decision/v1",
             "action" => "rejected",
             "reason" => "missing_action_contract"
           } = PolicyEngine.evaluate(%{})

    assert %{
             "schema_version" => "holt_policy_decision/v1",
             "action" => "rejected",
             "reason" => "invalid_plan_gate"
           } =
             PolicyEngine.evaluate(%{
               "action_contract" => action_contract("get_task", "read_only"),
               "plan_gate" => %{"gate_id" => "gate-1", "action" => "queued"},
               "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
             })

    assert %{
             "schema_version" => "holt_policy_decision/v1",
             "action" => "rejected",
             "reason" => "invalid_action_preflight"
           } =
             PolicyEngine.evaluate(%{
               "action_contract" => action_contract("get_task", "read_only"),
               "plan_gate" => %{"gate_id" => "gate-1", "action" => "approved"},
               "action_preflight" => %{
                 "preflight_id" => "preflight-1",
                 "result" => "blocked",
                 "blocked_checks" => "action_route_accepted"
               }
             })
  end

  defp action_contract(action, effect_scope) do
    %{
      "contract_id" => "contract-#{action}",
      "action" => action,
      "effect_scope" => effect_scope,
      "risk_level" => "low",
      "target_domain" => "task"
    }
  end
end
