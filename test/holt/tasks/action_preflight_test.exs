defmodule Holt.Tasks.ActionPreflightTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ActionPreflight

  test "passes canonical read-only preflight" do
    preflight =
      ActionPreflight.evaluate(%{
        "action_route" => action_route(),
        "action_contract" => action_contract(),
        "plan_contract" => plan_contract(),
        "plan_gate" => plan_gate()
      })

    assert preflight["schema_version"] == "holt_action_preflight/v1"
    assert preflight["result"] == "passed"
    assert preflight["action"] == "get_task"
    assert preflight["effect_scope"] == "read_only"
    assert preflight["blocked_checks"] == []
    assert preflight["approval_required_checks"] == []

    assert preflight["plan_gate"] == %{
             "gate_id" => "gate-1",
             "action" => "approved",
             "reason" => "active_plan_allows_action"
           }
  end

  test "does not use action contract embedded in route as a fallback" do
    assert %{
             "schema_version" => "holt_action_preflight/v1",
             "result" => "blocked",
             "checks" => [%{"reason" => "missing_action_contract"}]
           } =
             ActionPreflight.evaluate(%{
               "action_route" => action_route(),
               "plan_contract" => plan_contract(),
               "plan_gate" => plan_gate()
             })
  end

  test "requires explicit plan gate" do
    assert %{
             "schema_version" => "holt_action_preflight/v1",
             "result" => "blocked",
             "checks" => [%{"reason" => "missing_plan_gate"}]
           } =
             ActionPreflight.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => plan_contract()
             })
  end

  test "rejects atom-keyed attrs and nested contracts" do
    assert %{
             "schema_version" => "holt_action_preflight/v1",
             "result" => "blocked",
             "checks" => [%{"reason" => "invalid_attrs"}]
           } =
             ActionPreflight.evaluate(
               Map.put(%{"plan_contract" => plan_contract()}, :action_contract, action_contract())
             )

    assert %{
             "schema_version" => "holt_action_preflight/v1",
             "result" => "blocked",
             "checks" => [%{"reason" => "invalid_attrs"}]
           } =
             ActionPreflight.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => Map.put(action_contract(), :target_refs, %{}),
               "plan_contract" => plan_contract(),
               "plan_gate" => plan_gate()
             })
  end

  test "rejects invalid explicit contract shapes" do
    assert %{
             "schema_version" => "holt_action_preflight/v1",
             "result" => "blocked",
             "checks" => [%{"reason" => "invalid_action_contract"}]
           } =
             ActionPreflight.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => Map.put(action_contract(), "target_refs", "task-1"),
               "plan_contract" => plan_contract(),
               "plan_gate" => plan_gate()
             })

    assert %{
             "schema_version" => "holt_action_preflight/v1",
             "result" => "blocked",
             "checks" => [%{"reason" => "invalid_plan_contract"}]
           } =
             ActionPreflight.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => Map.put(plan_contract(), "allowed_actions", "get_task"),
               "plan_gate" => plan_gate()
             })

    assert %{
             "schema_version" => "holt_action_preflight/v1",
             "result" => "blocked",
             "checks" => [%{"reason" => "invalid_plan_gate"}]
           } =
             ActionPreflight.evaluate(%{
               "action_route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => plan_contract(),
               "plan_gate" => Map.put(plan_gate(), "action", "queued")
             })
  end

  test "requires approval for approved workspace-durable preflight" do
    action_contract =
      action_contract(%{
        "action" => "write",
        "effect_scope" => "workspace_durable",
        "risk_level" => "high",
        "target_refs" => %{"path" => "README.md"},
        "recovery" => %{"reversibility" => "reversible"},
        "idempotency_key" => "write:readme"
      })

    attrs = %{
      "action_route" => action_route(%{"action_contract" => action_contract}),
      "action_contract" => action_contract,
      "plan_contract" =>
        plan_contract(%{
          "allowed_actions" => ["write"],
          "allowed_effect_scopes" => ["workspace_durable"],
          "plan_steps" => [
            %{
              "step_id" => "step-2",
              "effect_scope" => "workspace_durable",
              "allowed_actions" => ["write"]
            }
          ]
        }),
      "plan_gate" => plan_gate()
    }

    assert %{
             "result" => "approval_required",
             "approval_required_checks" => ["approval_granted"]
           } = ActionPreflight.evaluate(attrs)

    assert %{"result" => "passed"} =
             attrs
             |> Map.put("approval_status", "approved")
             |> ActionPreflight.evaluate()
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
            "effect_scope" => "read_only",
            "allowed_actions" => ["get_task"]
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
end
