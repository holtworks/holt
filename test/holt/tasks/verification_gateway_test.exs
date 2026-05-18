defmodule Holt.Tasks.VerificationGatewayTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.VerificationGateway

  test "submits when checks and evidence contract pass" do
    gateway =
      VerificationGateway.evaluate(%{
        "checks" => [
          %{"check_type" => "behavior_check", "status" => "passed"}
        ]
      })

    assert %{
             "schema_version" => "holt_verification_gateway/v1",
             "status" => "submitted",
             "satisfied" => true,
             "route" => %{"status" => "auto_finish"},
             "verifier" => %{"status" => "approved"}
           } = gateway

    assert VerificationGateway.satisfied?(gateway)
  end

  test "keeps missing evidence requirements structured on route and verifier" do
    gateway =
      VerificationGateway.evaluate(%{
        "evidence_contract" => %{
          "required_check_groups" => [
            %{"group_id" => "behavior", "any_of" => ["behavior_check"]}
          ]
        },
        "checks" => [
          %{"check_type" => "command_check", "status" => "passed"}
        ]
      })

    assert gateway["status"] == "blocked"
    assert gateway["reason"] == "evidence_contract_not_satisfied"

    assert [%{"code" => "missing_check_group", "group_id" => "behavior"}] =
             gateway["route"]["missing_requirements"]

    assert gateway["route"]["missing_requirements"] ==
             gateway["verifier"]["missing_requirements"]
  end

  test "route helper returns only canonical route maps" do
    route = %{"schema_version" => "holt_verification_route/v1", "status" => "needs_review"}

    assert VerificationGateway.route(%{"route" => route}) == route

    assert VerificationGateway.route(%{"route" => %{schema_version: "route", status: "ok"}}) ==
             %{}

    assert VerificationGateway.route(%{"route" => nil}) == %{}
    assert VerificationGateway.route(%{}) == %{}
  end

  test "satisfied helper requires literal boolean true" do
    assert VerificationGateway.satisfied?(%{"satisfied" => true})
    refute VerificationGateway.satisfied?(%{"satisfied" => "true"})
    refute VerificationGateway.satisfied?(%{"satisfied" => 1})
  end

  test "rejects atom-keyed checks" do
    gateway =
      VerificationGateway.evaluate(%{
        "checks" => [
          %{check_type: "behavior_check", status: "passed"}
        ]
      })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_attrs",
             "satisfied" => false,
             "can_finish" => false
           } = gateway
  end

  test "rejects checks without the required structured fields" do
    gateway =
      VerificationGateway.evaluate(%{
        "checks" => [
          %{"check_type" => "behavior_check", "status" => "unknown"}
        ]
      })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_checks",
             "can_finish" => false
           } = gateway
  end

  test "rejects risk flags that are not a list" do
    gateway =
      VerificationGateway.evaluate(%{
        "checks" => [
          %{"check_type" => "behavior_check", "status" => "passed"}
        ],
        "risk_flags" => "needs_human_review"
      })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_risk_flags",
             "can_finish" => false
           } = gateway
  end

  test "rejects evidence lists with non-string values" do
    gateway =
      VerificationGateway.evaluate(%{
        "checks" => [
          %{"check_type" => "behavior_check", "status" => "passed"}
        ],
        "changed_files" => ["lib/holt/tasks.ex", :invalid]
      })

    assert %{
             "status" => "rejected",
             "reason" => "invalid_changed_files",
             "can_finish" => false
           } = gateway
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_verification_gateway/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs",
             "satisfied" => false,
             "can_finish" => false
           } = VerificationGateway.evaluate([])
  end
end
