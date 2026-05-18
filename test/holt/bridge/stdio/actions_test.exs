defmodule Holt.Bridge.Stdio.ActionsTest do
  use ExUnit.Case, async: true

  alias Holt.Bridge.Stdio.Actions
  alias Holt.ActionVisibility

  test "get requires action" do
    assert Actions.get(%{"name" => "read"}, []) == %{
             "ok" => false,
             "error" => "{:missing_required, \"action\"}"
           }
  end

  test "get returns an action by canonical name" do
    assert %{"ok" => true, "result" => %{"name" => "read"}} =
             Actions.get(%{"action" => "read"}, [])
  end

  test "read action schema uses path instead of task reference fields" do
    assert %{"ok" => true, "result" => %{"arguments_schema" => schema}} =
             Actions.get(%{"action" => "read"}, [])

    assert schema["required"] == ["path"]
    assert Map.has_key?(schema["properties"], "path")
    refute Map.has_key?(schema["properties"], "ref")
    refute Map.has_key?(schema["properties"], "task_ref")
    refute Map.has_key?(schema["properties"], "task_id")
  end

  test "workspace read rejects task reference fields instead of routing through tasks" do
    assert {:error, execution} =
             Holt.Actions.execute("read", %{"ref" => "AGENTS.md"}, workspace: tmp_workspace())

    assert execution["action"] == "read"
    assert execution["status"] == "error"
    assert execution["reason"] == "unsupported_argument:ref"
  end

  test "workspace write reports missing required arguments explicitly" do
    assert {:error, execution} = Holt.Actions.execute("write", %{}, workspace: tmp_workspace())

    assert execution["action"] == "write"
    assert execution["status"] == "error"
    assert execution["reason"] == "missing_required_arguments"
    assert execution["missing_arguments"] == ["path", "content"]
    assert execution["required_arguments"] == ["path", "content"]
    assert execution["received_arguments"] == []
    assert execution["retryable"] == true
  end

  test "read activity without a path does not invent a file label" do
    event = ActionVisibility.started("read", %{"ref" => "AGENTS.md"}, "call_1", [])

    assert event["label"] == "Reading file"
    refute event["label"] =~ "a file"
  end

  test "execute does not treat top-level fields as arguments" do
    assert %{"ok" => false, "error" => _reason, "result" => result} =
             Actions.execute(%{"action" => "read", "path" => "README.md"}, [])

    assert result["action"] == "read"
  end

  defp tmp_workspace do
    path =
      Path.join(System.tmp_dir!(), "holtworks-actions-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
