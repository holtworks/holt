defmodule Holt.AgentsTest do
  use ExUnit.Case

  alias Holt.{Agents, Workspace}

  test "profile writes require canonical fields" do
    workspace = tmp_workspace()
    Workspace.init(workspace)

    attrs = %{
      "agent_id" => "agent_alpha",
      "display_name" => "Alpha",
      "instructions" => "Handle bounded local work.",
      "skills" => ["Planning"],
      "work_roles" => ["planner"]
    }

    assert {:ok, profile} = Agents.create(workspace, attrs)
    assert profile["id"] == "agent_alpha"
    assert profile["default_work_role"] == "planner"

    assert Agents.create(
             workspace,
             Map.delete(attrs, "agent_id") |> Map.put("id", "agent_beta")
           ) == {:error, {:obsolete_agent_key, "id", "agent_id"}}

    assert Agents.create(
             workspace,
             %{
               agent_id: "agent_beta",
               display_name: "Beta",
               instructions: "Work.",
               skills: ["Plan"]
             }
           ) == {:error, :invalid_agent_attrs}

    assert Agents.update(workspace, "agent_alpha", %{"name" => "Legacy Name"}) ==
             {:error, {:obsolete_agent_key, "name", "display_name"}}

    assert Agents.update(workspace, "agent_alpha", %{display_name: "Beta"}) ==
             {:error, :invalid_agent_attrs}

    assert {:ok, updated} =
             Agents.update(workspace, "agent_alpha", %{"display_name" => "Alpha Prime"})

    assert updated["display_name"] == "Alpha Prime"
  end

  defp tmp_workspace do
    Path.join(System.tmp_dir!(), "holt-agents-#{random_id()}")
  end

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
