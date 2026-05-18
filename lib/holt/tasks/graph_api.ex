defmodule Holt.Tasks.GraphApi do
  @moduledoc """
  Public task graph operations with task-ref resolution.
  """

  alias Holt.Paths
  alias Holt.Tasks.{Repository, TaskGraphs}

  def list(ref_or_id, opts \\ []) do
    root = Paths.workspace_root(opts)

    with {:ok, task} <- Repository.get(ref_or_id, opts) do
      {:ok, TaskGraphs.list_for_task(root, task["id"])}
    end
  end

  def get(graph_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> TaskGraphs.get(graph_id)
  end

  def create(ref_or_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    root = Paths.workspace_root(opts)

    with {:ok, task} <- Repository.get(ref_or_id, opts) do
      TaskGraphs.create(root, task, attrs)
    end
  end

  def advance(graph_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> TaskGraphs.advance(graph_id, attrs)
  end

  def complete_node(graph_id, node_ref, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> TaskGraphs.complete_node(graph_id, node_ref, attrs)
  end

  def block_node(graph_id, node_ref, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> TaskGraphs.block_node(graph_id, node_ref, attrs)
  end
end
