defmodule Holt.Tasks.ContextContractTest do
  use ExUnit.Case, async: true

  alias Holt.{Tasks, Workspace}

  @moduletag :tmp_dir

  setup %{tmp_dir: workspace} do
    Workspace.init(workspace)
    {:ok, task} = Tasks.create(%{"title" => "Context contract"}, workspace: workspace)
    %{workspace: workspace, task: task}
  end

  test "task memory context rejects atom-keyed attrs", %{workspace: workspace, task: task} do
    assert Tasks.task_memory_context(task["ref"], %{content_limit: 500}, workspace: workspace) ==
             {:error, :invalid_attrs}
  end

  test "context budget rejects atom-keyed attrs", %{workspace: workspace, task: task} do
    assert Tasks.context_budget(
             task["ref"],
             %{messages: [%{"role" => "user", "content" => "hello"}]},
             workspace: workspace
           ) == {:error, :invalid_attrs}
  end

  test "continuation packet rejects atom-keyed attrs", %{workspace: workspace, task: task} do
    assert Tasks.continuation_packet(task["ref"], %{agent_work_id: "work-1"},
             workspace: workspace
           ) ==
             {:error, :invalid_attrs}
  end
end
