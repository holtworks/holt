defmodule Holt.Tasks.WorldStateSnapshotTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.WorldStateSnapshot

  test "builds snapshot from canonical task, context, contract, and plan fields" do
    snapshot =
      WorldStateSnapshot.build(%{
        "task" => %{
          "id" => "task-1",
          "ref" => "HW-1",
          "title" => "Ship",
          "status" => "open",
          "parent_id" => "parent-1"
        },
        "context" => %{
          "agent_id" => "agent-1",
          "agent_ref" => "A-1",
          "run_id" => "run-1",
          "work_role" => "verifier",
          "autonomous" => true,
          "approval_status" => "approved",
          "stale_state_detected" => true
        },
        "action_contract" => %{
          "contract_id" => "contract-1",
          "action" => "get_task",
          "effect_scope" => "read_only",
          "target_domain" => "task",
          "target_refs" => %{"task_ref" => "HW-1"}
        },
        "plan_contract" => %{
          "plan_id" => "plan-1",
          "allowed_actions" => ["get_task"],
          "allowed_effect_scopes" => ["read_only"],
          "status" => "active"
        }
      })

    assert snapshot["schema_version"] == "holt_world_state_snapshot/v1"
    assert snapshot["snapshot_id"]
    assert snapshot["state_hash"]
    assert snapshot["task_state"]["task_id"] == "task-1"
    assert snapshot["task_state"]["task_ref"] == "HW-1"
    assert snapshot["agent_state"]["agent_id"] == "agent-1"
    assert snapshot["agent_state"]["run_id"] == "run-1"
    assert snapshot["permission_state"]["approval_granted"] == true
    assert snapshot["permission_state"]["approval_source"] == "approval_status"
    assert snapshot["permission_state"]["verifier_context"] == true
    assert snapshot["staleness"]["markers"] == ["stale_state_detected"]
  end

  test "does not use non-canonical task and context aliases" do
    snapshot =
      WorldStateSnapshot.build(%{
        "context" => %{
          "task_id" => "context-task",
          "task_ref" => "context-ref",
          "parent_task_id" => "context-parent",
          "agent_run_id" => "non-canonical-run",
          "agent_role" => "verifier",
          "role" => "verifier"
        },
        "action_contract" => %{
          "contract_id" => "contract-1",
          "action" => "write",
          "effect_scope" => "workspace_durable",
          "target_domain" => "workspace",
          "target_refs" => %{"task_id" => "target-task", "task_ref" => "target-ref"}
        },
        "plan_contract" => %{
          "plan_id" => "plan-1",
          "allowed_actions" => ["write"],
          "allowed_effect_scopes" => ["workspace_durable"],
          "status" => "active"
        }
      })

    refute Map.has_key?(snapshot, "task_state")
    refute Map.has_key?(snapshot, "agent_state")
    assert snapshot["permission_state"]["verifier_context"] == false
  end

  test "rejects atom-keyed nested maps" do
    assert %{
             "schema_version" => "holt_world_state_snapshot/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             WorldStateSnapshot.build(%{
               "task" => %{id: "task-1", ref: "HW-1"},
               "context" => %{agent_id: "agent-1", work_role: "verifier"},
               "action_contract" => %{
                 contract_id: "contract-1",
                 action: "get_task",
                 effect_scope: "read_only",
                 target_domain: "task"
               },
               "plan_contract" => %{plan_id: "plan-1", allowed_actions: ["get_task"]}
             })
  end

  test "rejects non-literal booleans for permission and staleness decisions" do
    assert %{
             "schema_version" => "holt_world_state_snapshot/v1",
             "status" => "rejected",
             "reason" => "invalid_context"
           } =
             WorldStateSnapshot.build(%{
               "context" => %{
                 "approval_already_granted" => "true",
                 "policy_approval_granted" => "true",
                 "verifier_context" => "true",
                 "autonomous" => "true",
                 "stale_state_detected" => "true",
                 "resource_stale" => 1
               },
               "action_contract" => %{
                 "contract_id" => "contract-1",
                 "action" => "get_task",
                 "effect_scope" => "read_only"
               },
               "plan_contract" => %{"plan_id" => "plan-1"}
             })
  end

  test "requires explicit action and plan contracts" do
    assert %{
             "schema_version" => "holt_world_state_snapshot/v1",
             "status" => "rejected",
             "reason" => "missing_action_contract"
           } = WorldStateSnapshot.build(%{"plan_contract" => %{"plan_id" => "plan-1"}})

    assert %{
             "schema_version" => "holt_world_state_snapshot/v1",
             "status" => "rejected",
             "reason" => "missing_plan_contract"
           } =
             WorldStateSnapshot.build(%{
               "action_contract" => %{
                 "contract_id" => "contract-1",
                 "action" => "get_task",
                 "effect_scope" => "read_only"
               }
             })
  end

  test "rejects empty plan list entries" do
    assert %{
             "schema_version" => "holt_world_state_snapshot/v1",
             "status" => "rejected",
             "reason" => "invalid_plan_contract"
           } =
             WorldStateSnapshot.build(%{
               "action_contract" => %{
                 "contract_id" => "contract-1",
                 "action" => "get_task",
                 "effect_scope" => "read_only"
               },
               "plan_contract" => %{
                 "plan_id" => "plan-1",
                 "allowed_actions" => [""]
               }
             })
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_world_state_snapshot/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = WorldStateSnapshot.build([])
  end
end
