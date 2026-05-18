defmodule Holt.Tasks.ConsequenceGateTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ConsequenceGate

  test "rejects legacy contract and route arguments" do
    assert %{"action" => "rejected", "reason" => "unsupported_argument:contract"} =
             ConsequenceGate.evaluate(%{
               "contract" => %{"contract_id" => "legacy-contract", "action" => "read"}
             })

    assert %{"action" => "rejected", "reason" => "unsupported_argument:route"} =
             ConsequenceGate.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => plan_contract(),
               "plan_gate" => plan_gate(),
               "action_preflight" => action_preflight(),
               "route" => %{"status" => "accepted"}
             })
  end

  test "approves canonical read-only consequence gate" do
    gate =
      ConsequenceGate.evaluate(%{
        "action_route" => action_route(),
        "action_contract" => action_contract(),
        "plan_contract" => plan_contract(),
        "plan_gate" => plan_gate(),
        "action_preflight" => action_preflight()
      })

    assert gate["schema_version"] == "holt_consequence_gate/v1"
    assert gate["action"] == "approved"
    assert gate["action_contract"]["contract_id"] == "contract-1"
    assert gate["plan_gate"]["gate_id"] == "gate-1"
    assert gate["action_preflight"]["preflight_id"] == "preflight-1"
    assert gate["prediction"]["schema_version"] == "holt_consequence_prediction/v1"
    assert gate["state_snapshot"]["schema_version"] == "holt_world_state_snapshot/v1"

    assert gate["state_transition_prediction"]["schema_version"] ==
             "holt_state_transition_prediction/v1"

    assert gate["state_invariant_check"]["schema_version"] == "holt_state_invariant_check/v1"
  end

  test "requires explicit upstream contracts" do
    assert %{"action" => "rejected", "reason" => "missing_plan_gate"} =
             ConsequenceGate.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => plan_contract(),
               "action_preflight" => action_preflight()
             })

    assert %{"action" => "rejected", "reason" => "missing_action_preflight"} =
             ConsequenceGate.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => plan_contract(),
               "plan_gate" => plan_gate()
             })
  end

  test "rejects atom-keyed attrs and nested contracts" do
    assert %{"action" => "rejected", "reason" => "invalid_attrs"} =
             ConsequenceGate.evaluate(
               Map.put(%{"plan_contract" => plan_contract()}, :action_contract, action_contract())
             )

    assert %{"action" => "rejected", "reason" => "invalid_attrs"} =
             ConsequenceGate.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => Map.put(action_contract(), :target_refs, %{}),
               "plan_contract" => plan_contract(),
               "plan_gate" => plan_gate(),
               "action_preflight" => action_preflight()
             })
  end

  test "rejects invalid explicit contract shapes" do
    assert %{"action" => "rejected", "reason" => "invalid_action_contract"} =
             ConsequenceGate.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => Map.put(action_contract(), "target_refs", "task-1"),
               "plan_contract" => plan_contract(),
               "plan_gate" => plan_gate(),
               "action_preflight" => action_preflight()
             })

    assert %{"action" => "rejected", "reason" => "invalid_plan_contract"} =
             ConsequenceGate.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => Map.put(plan_contract(), "allowed_actions", "get_task"),
               "plan_gate" => plan_gate(),
               "action_preflight" => action_preflight()
             })

    assert %{"action" => "rejected", "reason" => "invalid_action_preflight"} =
             ConsequenceGate.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => plan_contract(),
               "plan_gate" => plan_gate(),
               "action_preflight" => Map.put(action_preflight(), "blocked_checks", "route")
             })
  end

  defp action_route(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "holt_action_route/v1",
        "route_id" => "route-1",
        "status" => "accepted",
        "reason" => "direct_action_allowed",
        "action_contract" => action_contract()
      },
      overrides
    )
  end

  defp action_contract(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "holt_action_contract/v1",
        "contract_id" => "contract-1",
        "action" => "get_task",
        "effect_scope" => "read_only",
        "risk_level" => "low",
        "target_domain" => "task",
        "target_refs" => %{}
      },
      overrides
    )
  end

  defp plan_contract(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "holt_plan_contract/v1",
        "plan_id" => "plan-1",
        "status" => "active",
        "allowed_actions" => ["get_task"],
        "allowed_effect_scopes" => ["read_only"],
        "plan_steps" => [
          %{
            "step_id" => "step-1",
            "allowed_actions" => ["get_task"],
            "effect_scope" => "read_only"
          }
        ]
      },
      overrides
    )
  end

  defp plan_gate(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "holt_plan_gate/v1",
        "gate_id" => "gate-1",
        "action" => "approved",
        "reason" => "active_plan_allows_action"
      },
      overrides
    )
  end

  defp action_preflight(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "holt_action_preflight/v1",
        "preflight_id" => "preflight-1",
        "result" => "passed",
        "checks" => [],
        "blocked_checks" => [],
        "approval_required_checks" => []
      },
      overrides
    )
  end
end
