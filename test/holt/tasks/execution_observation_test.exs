defmodule Holt.Tasks.ExecutionObservationTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ExecutionObservation

  test "execution observations use canonical contract status and change fields" do
    observation =
      ExecutionObservation.from_result(%{
        "action_contract" => action_contract(),
        "prediction" => prediction(),
        "state_transition_prediction" => state_transition(),
        "result_status" => "ok",
        "observed_state_changes" => [%{"state_key" => "task:1", "durable" => true}]
      })

    assert %{
             "schema_version" => "holt_execution_observation/v1",
             "contract_id" => "contract-1",
             "prediction_id" => "prediction-1",
             "state_transition_id" => "transition-1",
             "action" => "read",
             "status" => "ok",
             "observed_state_changes" => [
               %{"state_key" => "task:1", "durable" => true}
             ]
           } = observation
  end

  test "execution observations reject legacy fields" do
    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:contract"
           } =
             ExecutionObservation.from_result(%{
               "contract" => action_contract()
             })

    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:status"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(),
               "state_transition_prediction" => state_transition(),
               "status" => "ok"
             })

    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:state_changes"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(),
               "state_transition_prediction" => state_transition(),
               "state_changes" => [%{"state_key" => "legacy-change"}]
             })
  end

  test "execution observations reject atom-keyed nested contracts and changes" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => %{contract_id: "contract-1", action: "read"},
               "prediction" => prediction(),
               "state_transition_prediction" => state_transition(),
               "result_status" => "ok"
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(),
               "state_transition_prediction" => state_transition(),
               "result_status" => "ok",
               "observed_state_changes" => [%{state_key: "task:1", durable: true}]
             })
  end

  test "execution observations require explicit runtime contracts and status" do
    assert %{
             "status" => "rejected",
             "reason" => "missing_action_contract"
           } = ExecutionObservation.from_result(%{})

    assert %{
             "status" => "rejected",
             "reason" => "missing_prediction"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => action_contract()
             })

    assert %{
             "status" => "rejected",
             "reason" => "missing_state_transition_prediction"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => action_contract(),
               "prediction" => prediction()
             })

    assert %{
             "status" => "rejected",
             "reason" => "missing_result_status"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(),
               "state_transition_prediction" => state_transition()
             })
  end

  test "execution observations reject invalid explicit observation details" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_latency_ms"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(),
               "state_transition_prediction" => state_transition(),
               "result_status" => "ok",
               "latency_ms" => "3"
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_observed_state_changes"
           } =
             ExecutionObservation.from_result(%{
               "action_contract" => action_contract(),
               "prediction" => prediction(),
               "state_transition_prediction" => state_transition(),
               "result_status" => "ok",
               "observed_state_changes" => "task:1"
             })
  end

  test "execution observations synthesize observed changes from transition prediction" do
    observation =
      ExecutionObservation.from_result(%{
        "action_contract" => action_contract(),
        "prediction" => prediction(),
        "state_transition_prediction" => state_transition(),
        "result_status" => "ok"
      })

    assert %{
             "status" => "ok",
             "observed_state_changes" => [
               %{"state_key" => "task:expected", "observation_status" => "observed"}
             ]
           } = observation
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_execution_observation/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = ExecutionObservation.from_result([])
  end

  defp action_contract do
    %{
      "contract_id" => "contract-1",
      "action" => "read",
      "effect_scope" => "read_only"
    }
  end

  defp prediction, do: %{"prediction_id" => "prediction-1"}

  defp state_transition do
    %{
      "transition_id" => "transition-1",
      "expected_changes" => [%{"state_key" => "task:expected"}]
    }
  end
end
