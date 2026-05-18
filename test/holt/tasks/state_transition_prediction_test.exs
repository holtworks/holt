defmodule Holt.Tasks.StateTransitionPredictionTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.StateTransitionPrediction

  test "rejects legacy contract argument" do
    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "unsupported_argument:contract"
           } =
             StateTransitionPrediction.predict(%{
               "contract" => %{"contract_id" => "legacy-contract", "effect_scope" => "read_only"}
             })
  end

  test "rejects atom-keyed legacy contract argument" do
    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             StateTransitionPrediction.predict(%{
               contract: %{"contract_id" => "legacy-contract", "effect_scope" => "read_only"}
             })
  end

  test "derives scope and target domain from canonical action_contract" do
    transition =
      StateTransitionPrediction.predict(%{
        "action_contract" => %{
          "contract_id" => "contract-1",
          "action" => "get_task",
          "effect_scope" => "read_only",
          "target_domain" => "task",
          "target_refs" => %{"task_ref" => "TASK-1"}
        },
        "prediction" => %{
          "prediction_id" => "prediction-1",
          "effect_scope" => "workspace_durable",
          "target_domain" => "workspace",
          "possible_failures" => ["resource_missing"],
          "confidence" => 0.86
        },
        "state_snapshot" => %{"snapshot_id" => "snapshot-1", "state_hash" => "hash-1"}
      })

    assert transition["schema_version"] == "holt_state_transition_prediction/v1"
    assert transition["action_contract_id"] == "contract-1"
    assert transition["prediction_id"] == "prediction-1"
    assert transition["effect_scope"] == "read_only"
    assert transition["target_domain"] == "task"
    assert transition["failure_modes"] == ["resource_missing"]
    refute transition["requires_observation"]

    assert [%{"code" => "read_context", "target_ref" => "TASK-1"}] =
             transition["expected_changes"]
  end

  test "rejects atom-keyed nested maps" do
    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             StateTransitionPrediction.predict(%{
               "action_contract" => %{
                 contract_id: "contract-1",
                 effect_scope: "read_only",
                 target_domain: "task",
                 target_refs: %{"task_ref" => "TASK-1"}
               },
               "prediction" => %{possible_failures: ["resource_missing"]},
               "state_snapshot" => %{snapshot_id: "snapshot-1", state_hash: "hash-1"}
             })
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = StateTransitionPrediction.predict([])
  end

  test "requires explicit action contract prediction and state snapshot" do
    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "missing_action_contract"
           } = StateTransitionPrediction.predict(%{})

    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "missing_prediction"
           } =
             StateTransitionPrediction.predict(%{
               "action_contract" => action_contract()
             })

    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "missing_state_snapshot"
           } =
             StateTransitionPrediction.predict(%{
               "action_contract" => action_contract(),
               "prediction" => %{"prediction_id" => "prediction-1"}
             })
  end

  test "rejects invalid explicit field shapes" do
    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "invalid_prediction"
           } =
             StateTransitionPrediction.predict(%{
               "action_contract" => action_contract(),
               "prediction" => %{
                 "prediction_id" => "prediction-1",
                 "possible_failures" => "resource_missing"
               },
               "state_snapshot" => %{"snapshot_id" => "snapshot-1", "state_hash" => "hash-1"}
             })

    assert %{
             "schema_version" => "holt_state_transition_prediction/v1",
             "status" => "rejected",
             "reason" => "invalid_prediction"
           } =
             StateTransitionPrediction.predict(%{
               "action_contract" => action_contract(),
               "prediction" => %{
                 "prediction_id" => "prediction-1",
                 "possible_failures" => [""]
               },
               "state_snapshot" => %{"snapshot_id" => "snapshot-1", "state_hash" => "hash-1"}
             })
  end

  defp action_contract do
    %{
      "contract_id" => "contract-1",
      "action" => "get_task",
      "effect_scope" => "read_only",
      "target_domain" => "task"
    }
  end
end
