defmodule Holt.Tasks.StateInvariantCheckTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.StateInvariantCheck

  test "rejects legacy contract argument" do
    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "unsupported_argument:contract"
           } =
             StateInvariantCheck.evaluate(%{
               "contract" => %{"contract_id" => "legacy-contract", "effect_scope" => "read_only"}
             })
  end

  test "rejects atom-keyed legacy contract argument" do
    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "invalid_attrs"
           } =
             StateInvariantCheck.evaluate(%{
               contract: %{"contract_id" => "legacy-contract", "effect_scope" => "read_only"}
             })
  end

  test "blocks canonical verifier work_role from mutating actions" do
    check =
      StateInvariantCheck.evaluate(%{
        "context" => %{"work_role" => "verifier"},
        "action_contract" => mutating_contract(),
        "state_snapshot" => state_snapshot(),
        "state_transition_prediction" => state_transition()
      })

    assert check["schema_version"] == "holt_state_invariant_check/v1"
    assert check["status"] == "blocked"
    assert check["action"] == "rejected"
    assert "read_only_verifier_boundary" in check["blocked_invariants"]
  end

  test "does not infer verifier context from legacy role fields" do
    check =
      StateInvariantCheck.evaluate(%{
        "context" => %{"role" => "verifier", "agent_role" => "verifier"},
        "action_contract" => mutating_contract(),
        "state_snapshot" => state_snapshot(),
        "state_transition_prediction" => state_transition()
      })

    assert check["schema_version"] == "holt_state_invariant_check/v1"
    assert check["status"] == "passed"
    assert check["action"] == "approved"
    assert check["blocked_invariants"] == nil
  end

  test "rejects string booleans and atom-keyed nested maps" do
    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "invalid_attrs"
           } =
             StateInvariantCheck.evaluate(%{
               "context" => %{"verifier_context" => "true"},
               "action_contract" => %{
                 "contract_id" => "contract-1",
                 "action" => "write_file",
                 "effect_scope" => "workspace_durable",
                 "target_domain" => "workspace",
                 "recovery" => %{reversibility: "reversible"}
               },
               "state_snapshot" => %{
                 "snapshot_id" => "snapshot-1",
                 "state_hash" => "hash-1",
                 "staleness" => %{stale: true}
               },
               "state_transition_prediction" => %{
                 "transition_id" => "transition-1",
                 "requires_observation" => true,
                 "expected_changes" => [%{"change_id" => "change-1"}]
               }
             })
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "invalid_attrs"
           } = StateInvariantCheck.evaluate([])
  end

  test "requires explicit action contract snapshot and transition" do
    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "missing_action_contract"
           } = StateInvariantCheck.evaluate(%{})

    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "missing_state_snapshot"
           } =
             StateInvariantCheck.evaluate(%{
               "action_contract" => mutating_contract()
             })

    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "missing_state_transition_prediction"
           } =
             StateInvariantCheck.evaluate(%{
               "action_contract" => mutating_contract(),
               "state_snapshot" => state_snapshot()
             })
  end

  test "rejects invalid explicit field shapes" do
    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "invalid_state_transition_prediction"
           } =
             StateInvariantCheck.evaluate(%{
               "action_contract" => mutating_contract(),
               "state_snapshot" => state_snapshot(),
               "state_transition_prediction" =>
                 Map.put(state_transition(), "requires_observation", "true")
             })

    assert %{
             "schema_version" => "holt_state_invariant_check/v1",
             "status" => "rejected",
             "action" => "rejected",
             "reason" => "invalid_state_transition_prediction"
           } =
             StateInvariantCheck.evaluate(%{
               "action_contract" => mutating_contract(),
               "state_snapshot" => state_snapshot(),
               "state_transition_prediction" =>
                 Map.put(state_transition(), "expected_changes", ["change-1"])
             })
  end

  defp mutating_contract do
    %{
      "contract_id" => "contract-1",
      "action" => "write_file",
      "effect_scope" => "workspace_durable",
      "target_domain" => "workspace",
      "recovery" => %{"reversibility" => "reversible"}
    }
  end

  defp state_snapshot do
    %{
      "snapshot_id" => "snapshot-1",
      "state_hash" => "hash-1",
      "staleness" => %{"stale" => false}
    }
  end

  defp state_transition do
    %{
      "transition_id" => "transition-1",
      "requires_observation" => true,
      "expected_changes" => [
        %{
          "change_id" => "change-1",
          "state_key" => "workspace:file",
          "operation" => "write_or_execute"
        }
      ]
    }
  end
end
