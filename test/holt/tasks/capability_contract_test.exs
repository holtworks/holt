defmodule Holt.Tasks.CapabilityContractTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.CapabilityContract

  test "builds canonical contract from explicit fields" do
    contract =
      CapabilityContract.build(%{
        "role" => "verifier",
        "action" => "route_verification_review",
        "allowed_actions" => ["route_verification_review"],
        "required_actions" => ["route_verification_review"],
        "input_artifact_kinds" => ["handoff"],
        "expected_output_artifact_kinds" => ["verification_report"],
        "effect_scope" => "read_only",
        "risk_flags" => ["billing"],
        "evidence_contract" => %{
          "changed_files_required" => true,
          "required_check_groups" => [%{"any_of" => ["regression_check"]}]
        }
      })

    assert contract["schema_version"] == "holt_capability_contract/v1"
    assert contract["role"] == "verifier"
    assert contract["required_actions"] == ["route_verification_review"]
    assert contract["allowed_actions"] == ["route_verification_review"]
    assert contract["input_artifact_kinds"] == ["handoff"]
    assert contract["expected_output_artifact_kinds"] == ["verification_report"]
    assert contract["risk_flags"] == ["billing"]
    assert "inspect_changed_files" in contract["required_capabilities"]
    assert "check_type:regression_check" in contract["required_capabilities"]
  end

  test "rejects aliases atom keys string lists and string booleans" do
    assert CapabilityContract.build(%{
             :role => "verifier",
             "work_role" => "planner"
           }) == %{
             "schema_version" => "holt_capability_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }

    assert CapabilityContract.build(%{"allowed_actions" => "route_verification_review"}) == %{
             "schema_version" => "holt_capability_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_field:allowed_actions"
           }

    assert CapabilityContract.build(%{
             "evidence_contract" => %{
               "changed_files_required" => "true",
               "required_check_groups" => [%{any_of: ["regression_check"]}]
             }
           }) == %{
             "schema_version" => "holt_capability_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_field:evidence_contract"
           }
  end

  test "rejects invalid role and effect scope" do
    assert CapabilityContract.build(%{"role" => "manager"}) == %{
             "schema_version" => "holt_capability_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_field:role"
           }

    assert CapabilityContract.build(%{"effect_scope" => "database"}) == %{
             "schema_version" => "holt_capability_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_field:effect_scope"
           }
  end

  test "rejects non-map attrs" do
    assert CapabilityContract.build([]) == %{
             "schema_version" => "holt_capability_contract/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end
end
