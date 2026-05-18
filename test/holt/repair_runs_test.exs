defmodule Holt.RepairRunsTest do
  use ExUnit.Case, async: true

  alias Holt.{LocalActions, RepairRuns}

  describe "public contracts" do
    test "reject atom-keyed repair run attrs" do
      assert {:error, :invalid_repair_run_attrs} =
               RepairRuns.start(%{risk_level: "low"}, workspace: tmp_root())

      assert {:error, :invalid_repair_run_attrs} =
               RepairRuns.start(
                 %{
                   "risk_level" => "low",
                   "goal_contract" => %{original_issue: "atom nested"}
                 },
                 workspace: tmp_root()
               )
    end

    test "local repair action requires canonical repair_run_id" do
      root = tmp_root()
      run = started_run(root)

      assert {:error, :repair_run_id_required} =
               LocalActions.execute("get_repair_run", %{"id" => run["id"]}, workspace: root)

      assert {:ok, %{"repair_run" => fetched}} =
               LocalActions.execute("get_repair_run", %{"repair_run_id" => run["id"]},
                 workspace: root
               )

      assert fetched["id"] == run["id"]
    end

    test "requires literal booleans for prediction reconciliation" do
      root = tmp_root()
      run = started_run(root)

      assert {:error, {:invalid_boolean, "matched"}} =
               RepairRuns.reconcile_prediction(
                 %{
                   "repair_run_id" => run["id"],
                   "prediction_id" => "prediction-1",
                   "observation_id" => "observation-1",
                   "matched" => "true"
                 },
                 workspace: root
               )
    end
  end

  describe "drafts and checks" do
    test "string booleans do not drive repair decisions" do
      root = tmp_root()
      run = started_run(root)

      assert {:ok, architecture} =
               RepairRuns.draft_architecture_plan(
                 %{
                   "repair_run_id" => run["id"],
                   "problem_statement" => "Fix checkout.",
                   "external_facts_required" => "true"
                 },
                 workspace: root
               )

      assert architecture["architecture_plan_draft"]["external_facts_required"] == false

      assert {:ok, original_issue} =
               RepairRuns.execute_original_issue_check(
                 %{
                   "repair_run_id" => run["id"],
                   "goal_check" => %{"original_issue_fixed" => "true"}
                 },
                 workspace: root
               )

      assert original_issue["original_issue_check_execution"]["status"] == "failed"

      assert {:ok, related_issue} =
               RepairRuns.draft_related_issue_sweep(
                 %{
                   "repair_run_id" => run["id"],
                   "should_fix_now" => "true"
                 },
                 workspace: root
               )

      assert related_issue["related_issue_sweep_draft"]["status"] == "passed"
    end

    test "only literal false disables score recording" do
      root = tmp_root()
      run = started_run(root)

      assert {:ok, string_record} =
               RepairRuns.score_predictions(
                 %{"repair_run_id" => run["id"], "record" => "false"},
                 workspace: root
               )

      assert [_score] = string_record["repair_run"]["prediction_scores"]

      assert {:ok, literal_record} =
               RepairRuns.score_predictions(
                 %{"repair_run_id" => run["id"], "record" => false},
                 workspace: root
               )

      assert [_score] = literal_record["repair_run"]["prediction_scores"]
    end
  end

  defp started_run(root) do
    assert {:ok, payload} =
             RepairRuns.start(
               %{
                 "task_id" => "HW-1",
                 "risk_level" => "low",
                 "goal_contract" => %{"original_issue" => "Checkout fails."}
               },
               workspace: root
             )

    payload["repair_run"]
  end

  defp tmp_root do
    Path.join(System.tmp_dir!(), "holt_repair_runs_test_#{System.unique_integer([:positive])}")
  end
end
