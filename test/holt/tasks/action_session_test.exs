defmodule Holt.Tasks.ActionSessionTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ActionSession

  describe "build/1" do
    test "builds from canonical string-keyed session attrs" do
      session =
        ActionSession.build(%{
          "task" => %{"id" => "task-1", "ref" => "HW-1"},
          "agent_id" => "agent-1",
          "graph_id" => "graph-1",
          "connected_accounts" => %{"github" => %{"connected_account_id" => "acct-1"}},
          "todos" => [%{"content" => "Review", "status" => "in_progress"}]
        })

      assert session["schema_version"] == "holt_action_session/v1"
      assert session["task_id"] == "task-1"
      assert session["task_ref"] == "HW-1"
      assert session["agent_id"] == "agent-1"
      assert session["graph_id"] == "graph-1"
      assert session["connected_accounts"]["github"]["connected_account_id"] == "acct-1"
      assert [%{"content" => "Review", "status" => "in_progress"}] = session["todos"]
    end

    test "rejects atom-keyed attrs and nested todo maps" do
      assert %{
               "schema_version" => "holt_action_session/v1",
               "status" => "rejected",
               "reason" => "invalid_attrs"
             } =
               ActionSession.build(%{
                 task: %{"id" => "task-1", "ref" => "HW-1"},
                 graph_id: "graph-1"
               })

      assert %{
               "status" => "rejected",
               "reason" => "invalid_attrs"
             } =
               ActionSession.build(%{
                 "task" => %{"id" => "task-1", "ref" => "HW-1"},
                 "todos" => [%{content: "Review", status: "completed"}]
               })
    end

    test "uses literal workbench enabled values" do
      default_session = ActionSession.build(%{"workbench" => %{}})
      assert default_session["workbench"]["enabled"] == true

      disabled = ActionSession.build(%{"workbench" => %{"enabled" => false}})
      assert disabled["workbench"]["enabled"] == false

      assert %{
               "status" => "rejected",
               "reason" => "invalid_workbench"
             } = ActionSession.build(%{"workbench" => %{"enabled" => "true"}})
    end

    test "rejects legacy graph alias and invalid explicit lists" do
      assert %{
               "status" => "rejected",
               "reason" => "unsupported_argument:task_graph_id"
             } = ActionSession.build(%{"task_graph_id" => "legacy-graph"})

      assert %{
               "status" => "rejected",
               "reason" => "invalid_disabled_actions"
             } = ActionSession.build(%{"disabled_actions" => "write"})

      assert %{
               "status" => "rejected",
               "reason" => "invalid_enabled_action_groups"
             } = ActionSession.build(%{"enabled_action_groups" => ["task", 1]})
    end
  end
end
