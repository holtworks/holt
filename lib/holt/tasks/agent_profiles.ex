defmodule Holt.Tasks.AgentProfiles do
  @moduledoc """
  Workspace-local agent profile facade for task workflows.

  `Holt.Tasks` keeps the public API, while this module owns delegation to the
  durable agent profile store.
  """

  alias Holt.{Agents, Paths}

  def list(opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> Agents.list_for_root()
  end

  def create(attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.create(attrs)
  end

  def update(agent_id, attrs, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.update(agent_id, attrs)
  end

  def get(agent_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> Agents.get(agent_id)
  end

  def suspend(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.suspend(agent_id, attrs)
  end

  def resume(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.resume(agent_id, attrs)
  end

  def archive(agent_id, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    opts
    |> Paths.workspace_root()
    |> Agents.archive(agent_id, attrs)
  end

  def cards(opts \\ []) do
    root = Paths.workspace_root(opts)
    Agents.list_cards(root, opts)
  end

  def card(agent_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> Agents.card(agent_id)
  end

  def skills(agent_id, opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> Agents.list_skills(agent_id)
  end
end
