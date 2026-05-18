defmodule Holt.Tasks.VerifierCalibrationTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.VerifierCalibration

  test "builds approved calibration from canonical fields" do
    assert %{
             "schema_version" => "holt_verifier_calibration/v1",
             "verifier_agent_id" => "agent_verify",
             "verifier_assignment_id" => "assign-1",
             "verdict" => "approved",
             "later_outcome" => "matched",
             "accuracy_delta" => 0.04,
             "required_reviewers" => ["reviewer-1"],
             "outcome_source" => "objective_evaluation"
           } =
             VerifierCalibration.build(%{
               "verifier_agent_id" => "agent_verify",
               "verifier_assignment" => %{
                 "assignment_id" => "assign-1",
                 "work_product_ref" => "HW-1",
                 "selected_verifier" => %{"agent_id" => "agent_verify"}
               },
               "evaluation" => %{
                 "completion_decision" => "auto_finish_allowed",
                 "verification_status" => "passed",
                 "can_finish" => true,
                 "required_reviewers" => ["reviewer-1"]
               }
             })
  end

  test "rejects atom-keyed assignment input" do
    calibration =
      VerifierCalibration.build(%{
        :verifier_assignment => %{"assignment_id" => "assign-legacy"},
        "evaluation" => %{
          "completion_decision" => "auto_finish_allowed",
          "verification_status" => "passed",
          "can_finish" => "true"
        }
      })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = calibration
  end

  test "rejects string booleans in evaluation" do
    calibration =
      VerifierCalibration.build(%{
        "evaluation" => %{
          "completion_decision" => "auto_finish_allowed",
          "verification_status" => "passed",
          "can_finish" => "true"
        }
      })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_evaluation"
           } = calibration
  end

  test "rejects atom-keyed legacy verdict" do
    calibration =
      VerifierCalibration.build(%{
        verdict: %{
          "completion_decision" => "auto_finish_allowed",
          "verification_status" => "passed",
          "can_finish" => true
        }
      })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = calibration
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_verifier_calibration/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = VerifierCalibration.build([])
  end
end
