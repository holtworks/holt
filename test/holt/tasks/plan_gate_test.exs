defmodule Holt.Tasks.PlanGateTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.PlanGate

  test "approves canonical action inside the active plan" do
    gate =
      PlanGate.evaluate(%{
        "action_route" => action_route(),
        "action_contract" => action_contract(),
        "plan_contract" => plan_contract()
      })

    assert gate["schema_version"] == "holt_plan_gate/v1"
    assert gate["action"] == "approved"
    assert gate["reason"] == "active_plan_allows_action"
    assert gate["action_contract_id"] == "contract-1"
    assert gate["plan_id"] == "plan-1"
    assert gate["target_action"] == "get_task"
    assert gate["effect_scope"] == "read_only"
    assert gate["plan_step"] == %{"step_id" => "step-1", "effect_scope" => "read_only"}
  end

  test "does not use action contract embedded in route as a fallback" do
    assert %{
             "schema_version" => "holt_plan_gate/v1",
             "action" => "rejected",
             "reason" => "missing_action_contract"
           } =
             PlanGate.evaluate(%{
               "action_route" => action_route(),
               "plan_contract" => plan_contract()
             })
  end

  test "rejects unsupported route alias" do
    assert %{
             "schema_version" => "holt_plan_gate/v1",
             "action" => "rejected",
             "reason" => "unsupported_argument:route"
           } =
             PlanGate.evaluate(%{
               "route" => action_route(),
               "action_contract" => action_contract(),
               "plan_contract" => plan_contract()
             })
  end

  test "rejects atom-keyed attrs and nested contracts" do
    assert %{
             "schema_version" => "holt_plan_gate/v1",
             "action" => "rejected",
             "reason" => "invalid_attrs"
           } =
             PlanGate.evaluate(
               Map.put(%{"plan_contract" => plan_contract()}, :action_contract, action_contract())
             )

    assert %{
             "schema_version" => "holt_plan_gate/v1",
             "action" => "rejected",
             "reason" => "invalid_attrs"
           } =
             PlanGate.evaluate(%{
               "action_contract" => Map.put(action_contract(), :target_refs, %{}),
               "plan_contract" => plan_contract()
             })
  end

  test "rejects invalid contract shapes instead of normalizing them" do
    assert %{
             "schema_version" => "holt_plan_gate/v1",
             "action" => "rejected",
             "reason" => "invalid_action_contract"
           } =
             PlanGate.evaluate(%{
               "action_contract" => Map.put(action_contract(), "target_refs", "task-1"),
               "plan_contract" => plan_contract()
             })

    assert %{
             "schema_version" => "holt_plan_gate/v1",
             "action" => "rejected",
             "reason" => "invalid_plan_contract"
           } =
             PlanGate.evaluate(%{
               "action_contract" => action_contract(),
               "plan_contract" => Map.put(plan_contract(), "allowed_actions", "get_task")
             })
  end

  test "rejects invalid explicit action route" do
    assert %{
             "schema_version" => "holt_plan_gate/v1",
             "action" => "rejected",
             "reason" => "invalid_action_route"
           } =
             PlanGate.evaluate(%{
               "action_route" => Map.put(action_route(), "status", "queued"),
               "action_contract" => action_contract(),
               "plan_contract" => plan_contract()
             })
  end

  test "blocks mutating action against a target outside the active plan task" do
    gate =
      PlanGate.evaluate(%{
        "action_route" => action_route(),
        "action_contract" =>
          action_contract(%{
            "action" => "update_task",
            "effect_scope" => "task_durable",
            "target_refs" => %{"task_id" => "other-task"}
          }),
        "plan_contract" =>
          plan_contract(%{
            "task_id" => "task-1",
            "allowed_actions" => ["update_task"],
            "allowed_effect_scopes" => ["task_durable"],
            "plan_steps" => [
              %{
                "step_id" => "step-2",
                "effect_scope" => "task_durable",
                "allowed_actions" => ["update_task"]
              }
            ]
          })
      })

    assert gate["action"] == "rejected"
    assert gate["reason"] == "target_outside_plan_task"
    assert gate["target_proof"]["status"] == "blocked"
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
        "task_id" => "task-1",
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
end
