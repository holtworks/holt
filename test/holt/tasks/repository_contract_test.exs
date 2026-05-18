defmodule Holt.Tasks.RepositoryContractTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks

  @moduletag :tmp_dir

  setup %{tmp_dir: workspace} do
    {:ok, task} = Tasks.create(%{"title" => "Canonical task"}, workspace: workspace)
    %{workspace: workspace, task: task}
  end

  test "create rejects atom-keyed task attrs", %{workspace: workspace} do
    assert Tasks.create(%{title: "Atom task"}, workspace: workspace) == {:error, :invalid_attrs}

    assert Tasks.create(
             %{
               "title" => "Nested atom task",
               "labels" => [%{name: "atom-label"}]
             },
             workspace: workspace
           ) == {:error, :invalid_attrs}
  end

  test "update and label changes reject atom-keyed attrs", %{workspace: workspace, task: task} do
    assert Tasks.update(task["ref"], %{status: "done"}, workspace: workspace) ==
             {:error, :invalid_attrs}

    assert Tasks.add_label(task["ref"], %{name: "atom-label"}, workspace: workspace) ==
             {:error, :invalid_attrs}
  end

  test "spec and memory artifacts reject atom-keyed attrs", %{workspace: workspace, task: task} do
    assert Tasks.save_spec(
             task["ref"],
             %{
               "kind" => "decision",
               "content" => "Decision",
               "metadata" => %{source: "atom"}
             },
             workspace: workspace
           ) == {:error, :invalid_attrs}

    assert Tasks.record_task_memory_artifact(
             task["ref"],
             %{content: "Atom memory"},
             workspace: workspace
           ) == {:error, :invalid_attrs}
  end
end
