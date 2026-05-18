defmodule Holt.MemoryTest do
  use ExUnit.Case

  alias Holt.{Memory, Tasks, Workspace}

  @moduletag :tmp_dir

  setup %{tmp_dir: workspace} do
    Workspace.init(workspace)
    {:ok, workspace: workspace}
  end

  test "user memory requires canonical attrs and explicit categories", %{workspace: workspace} do
    assert Memory.remember_user(%{summary: "Prefers short notes", category: "preference"},
             workspace: workspace
           ) == {:error, :invalid_memory_attrs}

    assert Memory.remember_user(%{"summary" => "Prefers short notes"}, workspace: workspace) ==
             {:error, "category_required"}

    assert {:ok, memory} =
             Memory.remember_user(
               %{
                 "user_id" => "user_1",
                 "summary" => "Prefers short notes",
                 "category" => "preference"
               },
               workspace: workspace
             )

    assert memory["user_id"] == "user_1"
    assert memory["category"] == "preference"
  end

  test "user memory filters reject invalid values", %{workspace: workspace} do
    assert {:ok, _memory} =
             Memory.remember_user(
               %{
                 "user_id" => "user_1",
                 "summary" => "Prefers compact notes",
                 "category" => "preference"
               },
               workspace: workspace
             )

    assert Memory.list_user(%{"user_id" => "user_1", "category" => "legacy"},
             workspace: workspace
           ) == {:error, "category_invalid"}

    assert Memory.search_user(%{"user_id" => "user_1"}, workspace: workspace) ==
             {:error, "query_required"}

    assert Memory.forget_user(%{"user_id" => 1, "substring" => "compact"}, workspace: workspace) ==
             {:error, "user_id_invalid"}
  end

  test "project memory requires canonical long form contracts", %{workspace: workspace} do
    assert Memory.remember_project(
             %{summary: "Use explicit memory contracts", category: "structure"},
             workspace: workspace
           ) == {:error, :invalid_memory_attrs}

    assert Memory.save_project_plan(%{"title" => "Plan", "body" => "Body"}, workspace: workspace) ==
             {:error, "category_required"}

    assert Memory.save_project_research(
             %{
               "title" => "Research",
               "body" => "Body",
               "category" => "structure",
               "sources" => "not-a-list"
             },
             workspace: workspace
           ) == {:error, "sources_invalid"}

    assert Memory.recall_project(%{"project_id" => "project_1", "limit" => "1"},
             workspace: workspace
           ) == {:error, "limit_invalid"}
  end

  test "memory collection actions propagate contract errors", %{workspace: workspace} do
    assert {:error, %{"reason" => "category_invalid", "status" => "error"}} =
             Tasks.execute_action(
               "list_user_memories",
               %{"category" => "legacy"},
               workspace: workspace
             )

    assert {:error, %{"reason" => "limit_invalid", "status" => "error"}} =
             Tasks.execute_action(
               "recall_project_memory",
               %{"limit" => "1"},
               workspace: workspace
             )
  end
end
