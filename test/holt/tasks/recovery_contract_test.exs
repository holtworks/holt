defmodule Holt.Tasks.RecoveryContractTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.RecoveryContract

  describe "build/1" do
    test "builds task-durable recovery contracts from canonical attrs" do
      contract =
        RecoveryContract.build(%{
          "action" => "update_task",
          "effect_scope" => "task_durable",
          "risk_level" => "medium",
          "target_refs" => %{"task_ref" => "HW-01"}
        })

      assert contract["schema_version"] == "holt_recovery_contract/v1"
      assert contract["action"] == "update_task"
      assert contract["effect_scope"] == "task_durable"
      assert contract["risk_level"] == "medium"
      assert contract["rollback_plan"]["strategy"] == "compensating_task_update"
      assert contract["rollback_plan"]["target_refs"] == %{"task_ref" => "HW-01"}
      assert contract["requires_recovery_observation"] == true
      assert contract["requires_rollback_verification"] == true
    end

    test "keeps no-param runtime default explicit" do
      contract = RecoveryContract.build(%{})

      assert contract["schema_version"] == "holt_recovery_contract/v1"
      assert contract["action"] == "unknown"
      assert contract["effect_scope"] == "unknown"
      assert contract["risk_level"] == "high"
      assert contract["irreversible_risk"] == true
    end

    test "builds session-ephemeral recovery contracts" do
      contract =
        RecoveryContract.build(%{
          "action" => "manage_connection",
          "effect_scope" => "session_ephemeral",
          "risk_level" => "low"
        })

      assert contract["reversibility"] == "overwrite_session_state"
      assert contract["rollback_plan"]["strategy"] == "overwrite_session_state"
      assert contract["requires_recovery_observation"] == false
    end

    test "rejects atom-keyed attrs" do
      assert RecoveryContract.build(%{action: "update_task"}) == %{
               "schema_version" => "holt_recovery_contract/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
    end

    test "rejects invalid enum values" do
      assert RecoveryContract.build(%{"effect_scope" => "task"}) == %{
               "schema_version" => "holt_recovery_contract/v1",
               "status" => "rejected",
               "reason" => "invalid_field:effect_scope"
             }

      assert RecoveryContract.build(%{"risk_level" => "urgent"}) == %{
               "schema_version" => "holt_recovery_contract/v1",
               "status" => "rejected",
               "reason" => "invalid_field:risk_level"
             }
    end

    test "rejects invalid target refs" do
      assert RecoveryContract.build(%{"target_refs" => %{task_ref: "HW-01"}}) == %{
               "schema_version" => "holt_recovery_contract/v1",
               "status" => "rejected",
               "reason" => "invalid_field:target_refs"
             }
    end

    test "rejects non-map attrs" do
      assert RecoveryContract.build([]) == %{
               "schema_version" => "holt_recovery_contract/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
    end
  end
end
