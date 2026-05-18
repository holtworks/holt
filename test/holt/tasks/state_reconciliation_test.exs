defmodule Holt.Tasks.StateReconciliationTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.StateReconciliation

  test "state reconciliation uses transition action and observation changes" do
    reconciliation =
      StateReconciliation.reconcile(%{
        "state_transition_prediction" => transition(%{"action" => "read"}),
        "observation" =>
          observation(%{
            "observed_state_changes" => [%{"state_key" => "task:1", "durable" => true}]
          })
      })

    assert %{
             "schema_version" => "holt_state_reconciliation/v1",
             "state_transition_id" => "transition-1",
             "observation_id" => "observation-1",
             "action" => "read",
             "matched" => true,
             "expected_change_count" => 1,
             "observed_change_count" => 1,
             "repair_directive" => "continue"
           } = reconciliation
  end

  test "state reconciliation rejects non-canonical change aliases" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_observation"
           } =
             StateReconciliation.reconcile(%{
               "state_transition_prediction" => transition(),
               "observation" =>
                 observation(%{
                   "observed_state_changes" => [%{"change_id" => "task:1"}]
                 })
             })
  end

  test "state reconciliation rejects atom-keyed transition observation and changes" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             StateReconciliation.reconcile(%{
               "state_transition_prediction" => %{
                 transition_id: "transition-1",
                 action: "write",
                 expected_changes: [%{state_key: "task:1", verification_required: true}]
               },
               "observation" => %{
                 observation_id: "observation-1",
                 status: "ok",
                 observed_state_changes: [%{state_key: "task:1"}]
               }
             })
  end

  test "state reconciliation requires explicit contracts" do
    assert %{
             "status" => "rejected",
             "reason" => "missing_state_transition_prediction"
           } = StateReconciliation.reconcile(%{"observation" => observation()})

    assert %{
             "status" => "rejected",
             "reason" => "missing_observation"
           } = StateReconciliation.reconcile(%{"state_transition_prediction" => transition()})

    assert %{
             "status" => "rejected",
             "reason" => "invalid_state_transition_prediction"
           } =
             StateReconciliation.reconcile(%{
               "state_transition_prediction" => Map.delete(transition(), "expected_changes"),
               "observation" => observation()
             })
  end

  test "state reconciliation rejects legacy observed changes field" do
    assert %{
             "status" => "rejected",
             "reason" => "unsupported_argument:observed_changes"
           } =
             StateReconciliation.reconcile(%{
               "state_transition_prediction" => transition(),
               "observation" => observation(),
               "observed_changes" => [%{"state_key" => "task:1"}]
             })
  end

  test "state reconciliation reports missing and unexpected explicit changes" do
    reconciliation =
      StateReconciliation.reconcile(%{
        "state_transition_prediction" => transition(),
        "observation" =>
          observation(%{
            "observed_state_changes" => [%{"state_key" => "task:unexpected"}]
          })
      })

    assert %{
             "matched" => false,
             "missing_changes" => [%{"state_key" => "task:1"}],
             "unexpected_changes" => [%{"state_key" => "task:unexpected"}],
             "repair_directive" => "enter_repair_phase_with_missing_state_delta"
           } = reconciliation
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_state_reconciliation/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = StateReconciliation.reconcile([])
  end

  defp transition(attrs \\ %{}) do
    Map.merge(
      %{
        "transition_id" => "transition-1",
        "action" => "write",
        "effect_scope" => "workspace_durable",
        "target_domain" => "task",
        "expected_changes" => [
          %{
            "state_key" => "task:1",
            "verification_required" => true
          }
        ]
      },
      attrs
    )
  end

  defp observation(attrs \\ %{}) do
    Map.merge(
      %{
        "observation_id" => "observation-1",
        "status" => "ok",
        "observed_state_changes" => [%{"state_key" => "task:1"}]
      },
      attrs
    )
  end
end
