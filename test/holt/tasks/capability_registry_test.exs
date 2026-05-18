defmodule Holt.Tasks.CapabilityRegistryTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.CapabilityRegistry

  describe "lookup/2" do
    test "builds registered capability entries" do
      entry = CapabilityRegistry.lookup("get_task", %{})

      assert entry["schema_version"] == "holt_capability_registry_entry/v1"
      assert entry["registered"] == true
      assert entry["action"] == "get_task"
      assert entry["effect_scope"] == "read_only"
      assert entry["risk_level"] == "low"
    end

    test "does not recover action from attrs" do
      assert %{"action" => "unknown", "registered" => false} =
               CapabilityRegistry.lookup(nil, %{"action_name" => "get_task"})
    end

    test "uses canonical embedded action contract" do
      entry =
        CapabilityRegistry.lookup("write", %{
          "action_contract" => %{
            "action" => "write",
            "effect_scope" => "workspace_durable",
            "target_domain" => "workspace",
            "risk_level" => "high",
            "target_refs" => %{"path" => "README.md"}
          }
        })

      assert entry["state_write_model"]["target_refs"] == %{"path" => "README.md"}
      assert entry["approval_policy"]["mode"] == "human_required"
    end

    test "rejects atom-keyed attrs" do
      assert CapabilityRegistry.lookup("get_task", %{action_contract: %{}}) == %{
               "schema_version" => "holt_capability_registry_entry/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
    end

    test "rejects invalid action names" do
      assert CapabilityRegistry.lookup(:get_task, %{}) == %{
               "schema_version" => "holt_capability_registry_entry/v1",
               "status" => "rejected",
               "reason" => "invalid_action"
             }
    end

    test "rejects invalid embedded action contracts" do
      assert CapabilityRegistry.lookup("get_task", %{"action_contract" => %{target_refs: %{}}}) ==
               %{
                 "schema_version" => "holt_capability_registry_entry/v1",
                 "status" => "rejected",
                 "reason" => "invalid_field:action_contract"
               }

      assert CapabilityRegistry.lookup("get_task", %{
               "action_contract" => %{"target_refs" => "HW-1"}
             }) == %{
               "schema_version" => "holt_capability_registry_entry/v1",
               "status" => "rejected",
               "reason" => "invalid_field:target_refs"
             }
    end

    test "rejects non-map attrs" do
      assert CapabilityRegistry.lookup("get_task", []) == %{
               "schema_version" => "holt_capability_registry_entry/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             }
    end
  end
end
