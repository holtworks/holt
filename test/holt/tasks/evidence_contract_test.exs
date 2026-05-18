defmodule Holt.Tasks.EvidenceContractTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.EvidenceContract

  describe "evaluate/1" do
    test "evidence checks use check_type as the only type field" do
      contract = %{
        "required_check_groups" => [
          %{"group_id" => "regression", "any_of" => ["regression_check"]}
        ]
      }

      legacy =
        EvidenceContract.evaluate(%{
          "evidence_contract" => contract,
          "checks" => [
            %{"type" => "regression_check", "name" => "regression", "status" => "passed"}
          ]
        })

      assert legacy["satisfied"] == false
      assert legacy["supplied_check_types"] == nil
      assert [%{"code" => "missing_check_group"}] = legacy["missing_requirements"]

      canonical =
        EvidenceContract.evaluate(%{
          "evidence_contract" => contract,
          "checks" => [
            %{
              "check_type" => "regression_check",
              "name" => "regression",
              "status" => "passed"
            }
          ]
        })

      assert canonical["satisfied"] == true
      assert canonical["supplied_check_types"] == ["regression_check"]
    end

    test "rejects obsolete contract alias" do
      assert %{
               "schema_version" => "holt_evidence_contract_evaluation/v1",
               "status" => "rejected",
               "reason" => "obsolete_key:contract",
               "satisfied" => false
             } =
               EvidenceContract.evaluate(%{
                 "contract" => %{"changed_files_required" => true},
                 "changed_files" => ["lib/holt/tasks.ex"]
               })
    end

    test "requires literal booleans" do
      contract = %{
        "changed_files_required" => "true",
        "command_evidence_required" => true,
        "required_check_groups" => [
          %{"group_id" => "regression", "any_of" => ["regression_check"]}
        ]
      }

      evaluation =
        EvidenceContract.evaluate(%{
          "evidence_contract" => contract,
          "checks" => [
            %{
              "check_type" => "regression_check",
              "status" => "passed",
              "command" => "mix test"
            }
          ]
        })

      assert evaluation["satisfied"] == true

      assert evaluation["required_check_groups"] == [
               %{"group_id" => "regression", "any_of" => ["regression_check"]}
             ]

      refute Enum.any?(
               Map.get(evaluation, "missing_requirements", []),
               &(&1["code"] == "changed_files_required")
             )
    end

    test "rejects atom-keyed evaluation payloads" do
      assert %{
               "schema_version" => "holt_evidence_contract_evaluation/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs",
               "satisfied" => false
             } =
               EvidenceContract.evaluate(%{
                 "evidence_contract" => %{
                   "required_check_groups" => [
                     %{group_id: "atom", any_of: ["manual_review"]}
                   ]
                 }
               })
    end
  end

  describe "build/1" do
    test "rejects atom-keyed nested evidence contracts" do
      assert %{
               "schema_version" => "holt_evidence_contract/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             } =
               EvidenceContract.build(%{
                 "evidence_contract" => %{
                   changed_files_required: true,
                   required_check_groups: [%{any_of: ["regression_check"]}]
                 }
               })
    end
  end
end
