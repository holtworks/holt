defmodule Holt.Tasks.CapabilityIndexTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.CapabilityIndex

  test "capability profiles require canonical agent_id" do
    assert CapabilityIndex.profiles("agent-1") == []
    assert CapabilityIndex.profiles(%{agent_id: "agent-1", actions: ["read"]}) == []
    assert CapabilityIndex.profiles(%{"id" => "legacy-id", "actions" => ["read"]}) == []
    assert CapabilityIndex.profiles(%{"agent_ref" => "legacy-ref", "actions" => ["read"]}) == []
  end

  test "capability profiles use canonical action and display fields" do
    assert [profile] =
             CapabilityIndex.profiles(%{
               "agent_id" => "agent-1",
               "agent_ref" => "A-1",
               "ref" => "legacy-ref",
               "agent_handle" => "@agent-1",
               "handle" => "@legacy",
               "display_name" => "Agent One",
               "name" => "Legacy Name",
               "actions" => ["read"],
               "allowed_actions" => ["write"],
               "direct_actions" => ["search"]
             })

    assert profile["agent_id"] == "agent-1"
    assert profile["agent_ref"] == "A-1"
    assert profile["handle"] == "@agent-1"
    assert profile["name"] == "Agent One"
    assert profile["actions"] == ["read"]
    assert CapabilityIndex.action_available?(profile, "read")
    refute CapabilityIndex.action_available?(profile, "write")
    refute CapabilityIndex.action_available?(profile, "search")
  end
end
