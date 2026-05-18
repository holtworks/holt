defmodule Holt.Paths do
  @moduledoc """
  Resolves Holt global and workspace paths.
  """

  def home(opts \\ []) do
    case opts[:home] do
      value when value in [nil, ""] -> home_from_env()
      value -> value
    end
  end

  def workspace_root(opts \\ []) do
    case opts[:workspace] do
      value when value in [nil, ""] -> workspace_from_env()
      value -> value
    end
  end

  def workspace_dir(root), do: Path.join(root, ".holtworks")
  def config_path(home), do: Path.join(home, "config.json")
  def providers_path(home), do: Path.join(home, "providers.json")
  def gateway_status_path(home), do: Path.join(home, "gateway.json")
  def global_logs_dir(home), do: Path.join(home, "logs")
  def global_skills_dir(home), do: Path.join(home, "skills")
  def global_memory_dir(home), do: Path.join(home, "memory")

  def workspace_file(root, filename) do
    root
    |> workspace_dir()
    |> Path.join(filename)
  end

  def runs_dir(root), do: workspace_file(root, "runs")
  def sessions_dir(root), do: workspace_file(root, "sessions")
  def agent_events_dir(root), do: workspace_file(root, "agent_events")
  def research_claims_path(root), do: workspace_file(root, "research_claims.jsonl")
  def artifacts_dir(root), do: workspace_file(root, "artifacts")
  def approvals_dir(root), do: workspace_file(root, "approvals")
  def tasks_dir(root), do: workspace_file(root, "tasks")
  def task_specs_dir(root), do: Path.join(tasks_dir(root), "specs")
  def workspace_skills_dir(root), do: workspace_file(root, "skills")
  def workspace_memory_dir(root), do: workspace_file(root, "memory")

  def ensure_global(home) do
    [
      home,
      global_logs_dir(home),
      Path.join(home, "cache"),
      global_skills_dir(home),
      global_memory_dir(home)
    ]
    |> Enum.each(&File.mkdir_p!/1)

    :ok
  end

  def ensure_workspace(root) do
    [
      workspace_dir(root),
      workspace_skills_dir(root),
      workspace_memory_dir(root),
      runs_dir(root),
      sessions_dir(root),
      agent_events_dir(root),
      artifacts_dir(root),
      approvals_dir(root),
      tasks_dir(root),
      task_specs_dir(root)
    ]
    |> Enum.each(&File.mkdir_p!/1)

    :ok
  end

  defp home_from_env do
    case System.get_env("HOLTWORKS_HOME") do
      value when value in [nil, ""] -> Path.join(System.user_home!(), ".holtworks")
      value -> value
    end
  end

  defp workspace_from_env do
    case System.get_env("HOLTWORKS_WORKSPACE") do
      value when value in [nil, ""] -> File.cwd!()
      value -> value
    end
  end
end
