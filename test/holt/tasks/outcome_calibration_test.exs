defmodule Holt.Tasks.OutcomeCalibrationTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.OutcomeCalibration

  test "uses explicit upstream lifecycle contracts" do
    calibration =
      OutcomeCalibration.build(%{
        "action_contract" =>
          action_contract(%{
            "verification" => %{"suggested_checks" => ["check_workspace_diff"]}
          }),
        "prediction" => prediction(%{"confidence" => 0.5}),
        "observation" => observation(),
        "prediction_error" => prediction_error(%{"matched" => true, "severity" => "none"}),
        "state_reconciliation" => state_reconciliation(%{"matched" => true})
      })

    assert %{
             "schema_version" => "holt_outcome_calibration/v1",
             "prediction_id" => "prediction-1",
             "observation_id" => "observation-1",
             "state_reconciliation_id" => "reconciliation-1",
             "contract_id" => "contract-1",
             "action" => "write",
             "effect_scope" => "workspace_durable",
             "target_domain" => "workspace",
             "risk_level" => "high",
             "matched" => true,
             "state_matched" => true,
             "prediction_accuracy" => 1.0,
             "confidence_before" => 0.5,
             "confidence_after" => 0.54,
             "recommended_verification" => ["check_workspace_diff"],
             "recovery_recommendation" => "none"
           } = calibration
  end

  test "rejects atom-keyed nested maps" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             OutcomeCalibration.build(%{
               "action_contract" => %{
                 contract_id: "contract-1",
                 action: "write",
                 effect_scope: "workspace_durable",
                 target_domain: "workspace",
                 risk_level: "high"
               },
               "prediction" => %{prediction_id: "prediction-1", confidence: 0.8},
               "observation" => %{observation_id: "observation-1"},
               "prediction_error" => %{matched: true},
               "state_reconciliation" => %{matched: true}
             })
  end

  test "rejects invalid explicit booleans and confidence" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_prediction"
           } =
             OutcomeCalibration.build(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(%{"confidence" => "0.9"}),
               "observation" => observation(),
               "prediction_error" => prediction_error(),
               "state_reconciliation" => state_reconciliation()
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_prediction_error"
           } =
             OutcomeCalibration.build(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(),
               "observation" => observation(),
               "prediction_error" => prediction_error(%{"matched" => "true"}),
               "state_reconciliation" => state_reconciliation()
             })
  end

  test "uses mismatch policy without defaulting to reconciliation continue" do
    calibration =
      OutcomeCalibration.build(%{
        "action_contract" => action_contract(),
        "prediction" => prediction(),
        "observation" => observation(),
        "prediction_error" =>
          prediction_error(%{
            "matched" => false,
            "severity" => "high",
            "actual_result_status" => "error"
          }),
        "state_reconciliation" =>
          state_reconciliation(%{
            "matched" => true,
            "repair_directive" => "continue"
          })
      })

    assert %{
             "matched" => false,
             "state_matched" => true,
             "confidence_after" => 0.5,
             "recommended_verification" => [
               "check_preconditions",
               "capture_error_evidence",
               "retry_only_with_revised_plan"
             ],
             "recovery_recommendation" => "enter_repair_phase_with_new_prediction"
           } = calibration

    assert_in_delta calibration["prediction_accuracy"], 0.0, 0.0001
  end

  test "requires every upstream lifecycle record" do
    assert %{
             "status" => "rejected",
             "reason" => "missing_action_contract"
           } = OutcomeCalibration.build(%{})

    assert %{
             "status" => "rejected",
             "reason" => "missing_state_reconciliation"
           } =
             OutcomeCalibration.build(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(),
               "observation" => observation(),
               "prediction_error" => prediction_error()
             })
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_outcome_calibration/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = OutcomeCalibration.build([])
  end

  defp action_contract(attrs \\ %{}) do
    Map.merge(
      %{
        "contract_id" => "contract-1",
        "action" => "write",
        "effect_scope" => "workspace_durable",
        "target_domain" => "workspace",
        "risk_level" => "high"
      },
      attrs
    )
  end

  defp prediction(attrs \\ %{}) do
    Map.merge(
      %{
        "prediction_id" => "prediction-1",
        "confidence" => 0.72
      },
      attrs
    )
  end

  defp observation(attrs \\ %{}) do
    Map.merge(%{"observation_id" => "observation-1"}, attrs)
  end

  defp prediction_error(attrs \\ %{}) do
    Map.merge(
      %{
        "matched" => true,
        "severity" => "none",
        "expected_result_status" => "ok",
        "actual_result_status" => "ok",
        "lesson" => "prediction_matched_observation"
      },
      attrs
    )
  end

  defp state_reconciliation(attrs \\ %{}) do
    Map.merge(
      %{
        "reconciliation_id" => "reconciliation-1",
        "matched" => true,
        "state_delta_accuracy" => 1.0,
        "repair_directive" => "continue"
      },
      attrs
    )
  end
end
