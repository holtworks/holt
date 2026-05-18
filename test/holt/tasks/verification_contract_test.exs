defmodule Holt.Tasks.VerificationContractTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.VerificationContract

  test "builds canonical verification contract" do
    assert %{
             "schema_version" => "holt_verification_contract/v1",
             "required" => false,
             "gate_action" => "route_verification_review",
             "review_strategy" => "strict",
             "evidence_required" => false,
             "evidence_contract" => %{"changed_files_required" => true},
             "max_attempts" => 5,
             "pass_policy" => "passing_grade_required",
             "source" => "task_policy"
           } =
             VerificationContract.build(%{
               "verification_required" => false,
               "review_strategy" => "strict",
               "evidence_contract" => %{"changed_files_required" => true},
               "max_attempts" => 8,
               "require_passing_grade" => true,
               "source" => "task_policy"
             })
  end

  test "rejects non-canonical values" do
    assert %{
             "schema_version" => "holt_verification_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             VerificationContract.build(%{
               :verification_required => false,
               "verification_required" => false
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_verification_required"
           } =
             VerificationContract.build(%{
               "verification_required" => "false",
               "evidence_contract" => %{"changed_files_required" => true}
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_evidence_contract"
           } =
             VerificationContract.build(%{
               "evidence_contract" => "required"
             })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_max_attempts"
           } =
             VerificationContract.build(%{
               "max_attempts" => "5",
               "evidence_contract" => %{"changed_files_required" => true}
             })
  end

  test "rejects legacy verification fields" do
    assert %{
             "schema_version" => "holt_verification_contract/v1",
             "status" => "rejected",
             "reason" => "unsupported_argument:review_gate_mode"
           } = VerificationContract.build(%{"review_gate_mode" => "legacy_review"})
  end

  test "rejects non-map attrs" do
    assert VerificationContract.build([]) == %{
             "schema_version" => "holt_verification_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end
end
