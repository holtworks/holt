defmodule Holt.Tasks.MetaLearningLoopTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.MetaLearningLoop

  describe "build/1" do
    test "builds recommendations from literal structured outcomes" do
      snapshot =
        MetaLearningLoop.build(%{
          "outcome_calibrations" => [
            %{"calibration_id" => "cal-1", "action" => "write", "matched" => false}
          ],
          "repair_effectiveness" => [
            %{
              "repair_id" => "repair-1",
              "source_action" => "write",
              "effectiveness_status" => "pending_repair",
              "repair_required" => true
            }
          ],
          "verifier_quality" => [
            %{
              "verifier_agent_id" => "agent-verify",
              "accuracy" => 0.4,
              "calibration_count" => 3
            }
          ],
          "prior_lessons" => [
            %{"task_pattern_key" => "pattern-1", "application_mismatch_count" => 1}
          ]
        })

      assert snapshot["metrics"]["prediction_mismatch_count"] == 1
      assert snapshot["metrics"]["repair_required_count"] == 1

      assert Enum.map(snapshot["recommendations"], & &1["reason_code"]) == [
               "repeated_prediction_mismatch",
               "repair_not_resolved",
               "low_verifier_accuracy",
               "lesson_application_mismatch"
             ]
    end

    test "rejects atom-keyed attrs" do
      assert MetaLearningLoop.build(%{outcome_calibrations: []}) == %{
               "schema_version" => "holt_meta_learning_snapshot/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
    end

    test "rejects atom-keyed records" do
      assert MetaLearningLoop.build(%{
               "outcome_calibrations" => [
                 %{calibration_id: "atom-cal", action: "write", matched: false}
               ]
             }) == %{
               "schema_version" => "holt_meta_learning_snapshot/v1",
               "status" => "rejected",
               "reason" => "invalid_field:outcome_calibrations"
             }
    end

    test "rejects string booleans and numbers" do
      assert MetaLearningLoop.build(%{
               "outcome_calibrations" => [
                 %{"calibration_id" => "string-cal", "action" => "write", "matched" => "true"}
               ]
             }) == %{
               "schema_version" => "holt_meta_learning_snapshot/v1",
               "status" => "rejected",
               "reason" => "invalid_field:outcome_calibrations"
             }

      assert MetaLearningLoop.build(%{
               "verifier_quality" => [
                 %{
                   "verifier_agent_id" => "agent-verify",
                   "accuracy" => "0.4",
                   "calibration_count" => "3"
                 }
               ]
             }) == %{
               "schema_version" => "holt_meta_learning_snapshot/v1",
               "status" => "rejected",
               "reason" => "invalid_field:verifier_quality"
             }
    end

    test "rejects non-map attrs" do
      assert MetaLearningLoop.build([]) == %{
               "schema_version" => "holt_meta_learning_snapshot/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
    end
  end
end
