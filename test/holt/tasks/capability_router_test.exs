defmodule Holt.Tasks.CapabilityRouterTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.CapabilityRouter

  test "routes with canonical target_role" do
    route =
      CapabilityRouter.route(%{
        "capability_contract" => %{
          "contract_id" => "contract-1",
          "target_role" => "planner",
          "role" => "non-canonical",
          "effect_scope" => "read_only",
          "required_capabilities" => ["plan"],
          "required_actions" => ["inspect"]
        },
        "available_agents" => [
          %{
            "agent_id" => "agent-1",
            "status" => "active",
            "work_role" => "planner",
            "capabilities" => ["plan"],
            "actions" => ["inspect"],
            "effect_scopes" => ["read_only"]
          }
        ]
      })

    assert route["schema_version"] == "holt_capability_route/v1"
    assert route["status"] == "routed"
    assert route["target_role"] == "planner"
    assert route["target_agent_id"] == "agent-1"
  end

  test "does not route non-canonical role into target_role" do
    route =
      CapabilityRouter.route(%{
        "capability_contract" => %{
          "contract_id" => "contract-2",
          "role" => "non-canonical",
          "effect_scope" => "read_only",
          "required_capabilities" => ["plan"],
          "required_actions" => ["inspect"]
        },
        "available_agents" => []
      })

    assert route["schema_version"] == "holt_capability_route/v1"
    assert route["status"] == "ephemeral"
    assert route["score"] == 0
    refute Map.has_key?(route, "target_role")
  end

  test "rejects atom-keyed capability contract" do
    assert %{
             "schema_version" => "holt_capability_route/v1",
             "status" => "rejected",
             "reason" => "invalid_capability_contract"
           } =
             CapabilityRouter.route(%{
               "capability_contract" => %{
                 contract_id: "contract-3",
                 target_role: "planner",
                 effect_scope: "read_only",
                 required_capabilities: ["plan"]
               }
             })
  end

  test "rejects invalid explicit contract list fields" do
    assert %{
             "status" => "rejected",
             "reason" => "invalid_required_actions"
           } =
             CapabilityRouter.route(%{
               "capability_contract" => %{
                 "contract_id" => "contract-4",
                 "effect_scope" => "read_only",
                 "required_capabilities" => ["plan"],
                 "required_actions" => "inspect"
               }
             })
  end

  test "rejects atom-keyed agent candidates" do
    assert %{
             "schema_version" => "holt_capability_route/v1",
             "status" => "rejected",
             "reason" => "invalid_available_agents"
           } =
             CapabilityRouter.route(%{
               "capability_contract" => %{
                 "contract_id" => "contract-5",
                 "effect_scope" => "read_only",
                 "required_capabilities" => ["plan"],
                 "required_actions" => ["inspect"]
               },
               "available_agents" => [
                 %{
                   agent_id: "agent-1",
                   status: "active",
                   capabilities: ["plan"],
                   actions: ["inspect"],
                   effect_scopes: ["read_only"]
                 }
               ]
             })
  end

  test "rejects atom-keyed attrs" do
    assert %{
             "schema_version" => "holt_capability_route/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = CapabilityRouter.route(%{available_agents: []})
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_capability_route/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = CapabilityRouter.route([])
  end
end
