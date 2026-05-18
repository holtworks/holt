defmodule Holt.Tasks.PredictionErrorTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.PredictionError

  test "compares canonical prediction and observation contracts" do
    error =
      PredictionError.compare(%{
        "prediction" => prediction(%{"expected_result_status" => "ok", "risk_level" => "low"}),
        "observation" => observation(%{"status" => "ok"})
      })

    assert %{
             "schema_version" => "holt_prediction_error/v1",
             "prediction_id" => "prediction-1",
             "observation_id" => "observation-1",
             "contract_id" => "contract-1",
             "expected_result_status" => "ok",
             "actual_result_status" => "ok",
             "matched" => true,
             "severity" => "none",
             "lesson" => "prediction_matched_observation"
           } = error

    refute Map.has_key?(error, "missed_effects")
  end

  test "uses prediction contract id and rejects missing prediction contract id" do
    error =
      PredictionError.compare(%{
        "prediction" => prediction(%{"contract_id" => "prediction-contract"}),
        "observation" => observation(%{"contract_id" => "observation-contract"})
      })

    assert error["contract_id"] == "prediction-contract"

    assert %{
             "status" => "rejected",
             "reason" => "invalid_prediction"
           } =
             PredictionError.compare(%{
               "prediction" => Map.delete(prediction(), "contract_id"),
               "observation" => observation()
             })
  end

  test "records mismatch details from explicit statuses" do
    error =
      PredictionError.compare(%{
        "prediction" =>
          prediction(%{
            "expected_result_status" => "ok_or_awaiting_external_completion",
            "risk_level" => "high"
          }),
        "observation" => observation(%{"status" => "error"})
      })

    assert %{
             "matched" => false,
             "severity" => "high",
             "expected_result_status" => "ok_or_awaiting_external_completion",
             "actual_result_status" => "error",
             "missed_effects" => [
               "expected_result_status=ok_or_awaiting_external_completion",
               "actual_result_status=error"
             ],
             "lesson" => "future_plans_should_model_action_failure_before_retry"
           } = error
  end

  test "accepts explicit blocked-before-execution matches" do
    error =
      PredictionError.compare(%{
        "prediction" => prediction(%{"expected_result_status" => "blocked_before_execution"}),
        "observation" => observation(%{"status" => "await_approval"})
      })

    assert %{"matched" => true, "severity" => "none"} = error
  end

  test "rejects atom-keyed prediction and observation maps" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             PredictionError.compare(%{
               "prediction" => %{
                 prediction_id: "prediction-1",
                 contract_id: "contract-1",
                 expected_result_status: "ok"
               },
               "observation" => %{
                 observation_id: "observation-1",
                 status: "ok"
               }
             })
  end

  test "rejects missing and invalid explicit contracts" do
    assert %{
             "status" => "rejected",
             "reason" => "missing_prediction"
           } = PredictionError.compare(%{"observation" => observation()})

    assert %{
             "status" => "rejected",
             "reason" => "missing_observation"
           } = PredictionError.compare(%{"prediction" => prediction()})

    assert %{
             "status" => "rejected",
             "reason" => "invalid_prediction"
           } =
             PredictionError.compare(%{
               "prediction" => prediction(%{"expected_result_status" => "passed"}),
               "observation" => observation()
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_observation"
           } =
             PredictionError.compare(%{
               "prediction" => prediction(),
               "observation" => observation(%{"status" => "completed"})
             })
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_prediction_error/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = PredictionError.compare([])
  end

  defp prediction(attrs \\ %{}) do
    Map.merge(
      %{
        "prediction_id" => "prediction-1",
        "contract_id" => "contract-1",
        "expected_result_status" => "ok",
        "risk_level" => "low"
      },
      attrs
    )
  end

  defp observation(attrs \\ %{}) do
    Map.merge(
      %{
        "observation_id" => "observation-1",
        "status" => "ok"
      },
      attrs
    )
  end
end
