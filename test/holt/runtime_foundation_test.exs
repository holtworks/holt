defmodule Holt.RuntimeFoundationTest do
  use ExUnit.Case

  alias Holt.Paths
  alias Holt.Runtime.{Runs, SessionStore}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    runs_dir = Path.join(root, "ephemeral-runs")

    File.mkdir_p!(home)
    File.mkdir_p!(workspace)
    Paths.ensure_workspace(workspace)

    %{home: home, workspace: workspace, runs_dir: runs_dir}
  end

  test "paths resolve explicit opts before environment defaults", %{
    home: home,
    workspace: workspace
  } do
    previous_home = System.get_env("HOLTWORKS_HOME")
    previous_workspace = System.get_env("HOLTWORKS_WORKSPACE")

    System.put_env("HOLTWORKS_HOME", Path.join(home, "env-home"))
    System.put_env("HOLTWORKS_WORKSPACE", Path.join(workspace, "env-workspace"))

    on_exit(fn ->
      restore_env("HOLTWORKS_HOME", previous_home)
      restore_env("HOLTWORKS_WORKSPACE", previous_workspace)
    end)

    assert Paths.home(home: home) == home
    assert Paths.workspace_root(workspace: workspace) == workspace
    assert Paths.home() == Path.join(home, "env-home")
    assert Paths.workspace_root() == Path.join(workspace, "env-workspace")
  end

  test "workspace runs use explicit defaults and canonical run lookup", %{workspace: workspace} do
    assert {:ok, run} =
             Runs.start("hello runtime", workspace: workspace)

    assert run["agent_id"] == "default"
    refute Map.has_key?(run, "agent")
    assert run["model"] == "local:local-planner"
    assert run["safety_mode"] == "approval_required"
    assert run["permission_mode"] == "review"

    assert Runs.find(workspace, run["id"])["id"] == run["id"]
    assert Runs.find(workspace, Path.basename(run["run_dir"]))["id"] == run["id"]
  end

  test "session store preserves inserted timestamp across updates", %{workspace: workspace} do
    assert {:ok, first} =
             SessionStore.upsert("session-1", %{"status" => "running"}, workspace: workspace)

    assert {:ok, second} =
             SessionStore.upsert("session-1", %{"status" => "completed"}, workspace: workspace)

    assert second["inserted_at"] == first["inserted_at"]
    assert second["updated_at"] >= first["updated_at"]

    assert [%{"session_id" => "session-1", "status" => "completed"}] =
             SessionStore.resumable(workspace: workspace, statuses: ["completed"])
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
