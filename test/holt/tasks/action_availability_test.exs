defmodule Holt.Tasks.ActionAvailabilityTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ActionAvailability

  test "uses canonical workspace_status for workspace availability" do
    [available] = ActionAvailability.snapshot(%{"action_names" => ["list"]})
    assert available["name"] == "list"
    assert available["available"] == true

    [blocked] =
      ActionAvailability.snapshot(%{
        "action_names" => ["list"],
        "workspace_status" => "missing"
      })

    assert blocked["available"] == false
    assert blocked["unavailable_reason"] == "workspace_required"
    assert blocked["retryable"] == true
  end

  test "does not infer workspace availability from blocker_code" do
    [record] =
      ActionAvailability.snapshot(%{
        "action_names" => ["list"],
        "blocker_code" => "workspace_required"
      })

    assert record["available"] == true
    refute Map.has_key?(record, "unavailable_reason")
  end

  test "uses canonical network_status for network availability" do
    [blocked] =
      ActionAvailability.snapshot(%{
        "action_names" => ["fetch"],
        "network_status" => "disabled"
      })

    assert blocked["available"] == false
    assert blocked["unavailable_reason"] == "network_disabled"
  end

  test "does not infer network availability from network_enabled" do
    [record] =
      ActionAvailability.snapshot(%{
        "action_names" => ["fetch"],
        "network_enabled" => false
      })

    assert record["available"] == true
    refute Map.has_key?(record, "unavailable_reason")
  end

  test "rejects atom-keyed attrs and string availability" do
    assert ActionAvailability.snapshot(%{action_names: ["list"], workspace_status: "missing"}) ==
             [
               %{
                 "schema_version" => "holt_action_availability/v1",
                 "status" => "rejected",
                 "reason" => "invalid_attrs"
               }
             ]

    refute ActionAvailability.available?(
             [%{"name" => "list", "available" => "true"}],
             "list"
           )
  end

  test "rejects invalid action name lists" do
    assert ActionAvailability.snapshot(%{"action_names" => ["list", :fetch]}) == [
             %{
               "schema_version" => "holt_action_availability/v1",
               "status" => "rejected",
               "reason" => "invalid_field:action_names"
             }
           ]
  end

  test "rejects invalid status fields" do
    assert ActionAvailability.snapshot(%{
             "action_names" => ["list"],
             "workspace_status" => "gone"
           }) == [
             %{
               "schema_version" => "holt_action_availability/v1",
               "status" => "rejected",
               "reason" => "invalid_field:workspace_status"
             }
           ]
  end

  test "rejects non-map attrs" do
    assert ActionAvailability.snapshot([]) == [
             %{
               "schema_version" => "holt_action_availability/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
           ]
  end
end
