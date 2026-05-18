defmodule Holt.Bridge.NativeCommandTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Holt.Bridge
  alias Holt.Runtime.Runs

  test "model reports configured provider" do
    %{home: home} = tmp_env()

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "model",
                 "params" => %{"home" => home}
               }) == 0
      end)

    assert output =~ "Provider: local"
    assert output =~ "Type: local"
    assert output =~ "Model: local-planner"
    assert output =~ "Validation: ok"
  end

  test "model emits structured json for provider override" do
    %{home: home} = tmp_env()
    previous = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")
    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous) end)

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "model",
                 "params" => %{
                   "home" => home,
                   "json" => true,
                   "provider" => "openrouter",
                   "model" => "openai/gpt-4o-mini"
                 }
               }) == 0
      end)

    status = Jason.decode!(output)

    assert status["schema_version"] == "holt_model_status/v1"
    assert status["provider"] == "openrouter"
    assert status["type"] == "openrouter"
    assert status["model"] == "openai/gpt-4o-mini"
    assert status["api_key_env"] == "OPENROUTER_API_KEY"
    assert status["valid"] == false
    assert status["validation"] =~ "missing_env"
  end

  test "diff reports tracked staged and untracked workspace changes" do
    %{workspace: workspace} = tmp_env()
    init_git_workspace(workspace)
    File.write!(Path.join(workspace, "README.md"), "old\nsame\n")
    git!(workspace, ["add", "README.md"])

    git!(workspace, [
      "-c",
      "user.email=holt@example.com",
      "-c",
      "user.name=Holt",
      "commit",
      "-m",
      "init"
    ])

    File.write!(Path.join(workspace, "README.md"), "new\nsame\nextra\n")
    File.write!(Path.join(workspace, "STAGED.md"), "staged\n")
    git!(workspace, ["add", "STAGED.md"])
    File.write!(Path.join(workspace, "NOTES.md"), "untracked\n")

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "diff",
                 "params" => %{"workspace" => workspace}
               }) == 0
      end)

    assert output =~ "Workspace changes"
    assert output =~ "• Edited README.md (+2 -1)"
    assert output =~ "• Added STAGED.md (+1 -0)"
    assert output =~ "• Added NOTES.md (+1 -0)"
    assert output =~ "### Edited README.md (+2 -1)"
    assert output =~ "### Added STAGED.md (+1 -0)"
    assert output =~ "### Added NOTES.md (+1 -0)"
    assert output =~ "```diff"
    assert output =~ "--- a/README.md"
    assert output =~ "+++ b/README.md"
    assert output =~ "-old"
    assert output =~ "+new"
    assert output =~ "+++ b/STAGED.md"
    assert output =~ "+++ b/NOTES.md"

    json_output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "diff",
                 "params" => %{"workspace" => workspace, "json" => true}
               }) == 0
      end)

    diff = Jason.decode!(json_output)
    assert diff["schema_version"] == "holt_workspace_diff/v1"
    assert diff["workspace"] == workspace
    assert diff["view"] == "full"

    assert Enum.find(diff["files"], &(&1["path"] == "README.md")) == %{
             "path" => "README.md",
             "label" => "Edited",
             "additions" => 2,
             "deletions" => 1
           }

    assert Enum.find(diff["files"], &(&1["path"] == "STAGED.md")) == %{
             "path" => "STAGED.md",
             "label" => "Added",
             "additions" => 1,
             "deletions" => 0
           }

    assert Enum.find(diff["files"], &(&1["path"] == "NOTES.md")) == %{
             "path" => "NOTES.md",
             "label" => "Added",
             "additions" => 1,
             "deletions" => 0
           }

    assert diff["diff"] =~ "@@"

    summary_output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "diff",
                 "params" => %{"workspace" => workspace, "view" => "summary"}
               }) == 0
      end)

    assert summary_output =~ "Workspace changes"
    assert summary_output =~ "• Edited README.md (+2 -1)"
    assert summary_output =~ "• Added STAGED.md (+1 -0)"
    refute summary_output =~ "### Edited README.md"
    refute summary_output =~ "```diff"

    summary_json_output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "diff",
                 "params" => %{"workspace" => workspace, "json" => true, "view" => "summary"}
               }) == 0
      end)

    summary = Jason.decode!(summary_json_output)
    assert summary["view"] == "summary"
    assert Enum.find(summary["files"], &(&1["path"] == "README.md"))
    refute Map.has_key?(summary, "diff")
  end

  test "diff reports renamed workspace changes" do
    %{workspace: workspace} = tmp_env()
    init_git_workspace(workspace)
    File.write!(Path.join(workspace, "OLD.md"), "same\n")
    git!(workspace, ["add", "OLD.md"])

    git!(workspace, [
      "-c",
      "user.email=holt@example.com",
      "-c",
      "user.name=Holt",
      "commit",
      "-m",
      "init"
    ])

    git!(workspace, ["mv", "OLD.md", "NEW.md"])

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "diff",
                 "params" => %{"workspace" => workspace}
               }) == 0
      end)

    assert output =~ "• Renamed OLD.md -> NEW.md (+0 -0)"
    assert output =~ "### Renamed OLD.md -> NEW.md (+0 -0)"
    assert output =~ "rename from OLD.md"
    assert output =~ "rename to NEW.md"

    json_output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "diff",
                 "params" => %{"workspace" => workspace, "json" => true}
               }) == 0
      end)

    diff = Jason.decode!(json_output)

    assert Enum.find(diff["files"], &(&1["path"] == "NEW.md")) == %{
             "path" => "NEW.md",
             "previous_path" => "OLD.md",
             "label" => "Renamed",
             "additions" => 0,
             "deletions" => 0
           }
  end

  test "run with deny permission mode blocks write actions" do
    %{home: home, workspace: workspace} = tmp_env()

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "run",
                 "params" => %{
                   "home" => home,
                   "workspace" => workspace,
                   "permission_mode" => "deny",
                   "objective" => "inspect this folder and create a short implementation plan"
                 }
               }) == 0
      end)

    assert output =~ "Permissions: deny"
    assert output =~ "Status: blocked"
    refute File.exists?(Path.join(workspace, "NEXT_STEPS.md"))

    [run | _rest] = Runs.list(workspace)
    assert run["permission_mode"] == "deny"
    assert run["status"] == "blocked"
  end

  test "run rejects conflicting permission flags" do
    %{home: home, workspace: workspace} = tmp_env()

    stderr =
      capture_io(:stderr, fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "run",
                 "params" => %{
                   "home" => home,
                   "workspace" => workspace,
                   "permission_mode" => "deny",
                   "yes" => true,
                   "objective" => "inspect this folder"
                 }
               }) == 64
      end)

    assert stderr =~ "conflicting_permission_flags"
    assert stderr =~ "permission_mode"
    assert stderr =~ "yes"
  end

  test "logs can inspect a selected run" do
    %{workspace: workspace} = tmp_env()
    {:ok, first} = Runs.start("first selected objective", workspace: workspace)
    {:ok, second} = Runs.start("second objective", workspace: workspace)

    Runs.append_event(first["run_dir"], "action.approval_requested", %{
      "action_call_id" => "action_call_approval",
      "action" => "write",
      "status" => "awaiting_approval",
      "label" => "Writing file README.md",
      "risk" => "write",
      "input_summary" => %{"path" => "README.md"}
    })

    Runs.append_event(first["run_dir"], "action.approval_resolved", %{
      "action_call_id" => "action_call_approval",
      "action" => "write",
      "status" => "approved",
      "label" => "Approved Write file",
      "risk" => "write",
      "input_summary" => %{"path" => "README.md"}
    })

    Runs.append_transcript(first["run_dir"], "user", "Selected user prompt")
    Runs.append_transcript(first["run_dir"], "assistant", "Selected final answer")

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "logs",
                 "params" => %{
                   "workspace" => workspace,
                   "run_ref" => first["id"]
                 }
               }) == 0
      end)

    assert output =~ "Run: #{first["id"]}"
    assert output =~ "Objective: first selected objective"
    assert output =~ "Approvals:"

    assert output =~
             "• approved · Approved Write file · action: write · risk: write · path: README.md"

    assert output =~ "Answer:\nSelected final answer"
    refute output =~ "Run: #{second["id"]}"

    transcript_output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "logs",
                 "params" => %{
                   "workspace" => workspace,
                   "run_ref" => first["id"],
                   "view" => "transcript"
                 }
               }) == 0
      end)

    assert transcript_output =~ "Run: #{first["id"]}"
    assert transcript_output =~ "Transcript:"
    assert transcript_output =~ "## user\n\nSelected user prompt"
    assert transcript_output =~ "## assistant\n\nSelected final answer"
    refute transcript_output =~ "Approvals:"
    refute transcript_output =~ "Answer:"

    assert [
             %{
               "schema_version" => "holt_run_transcript_entry/v1",
               "role" => "user",
               "content" => "Selected user prompt"
             },
             %{
               "schema_version" => "holt_run_transcript_entry/v1",
               "role" => "assistant",
               "content" => "Selected final answer"
             }
           ] = Runs.transcript_entries(first["run_dir"])
  end

  test "runs json lists run summaries with latest answer" do
    %{workspace: workspace} = tmp_env()
    {:ok, first} = Runs.start("first run objective", workspace: workspace)
    Runs.append_transcript(first["run_dir"], "assistant", "First answer")
    {:ok, _first} = Runs.transition(first["run_dir"], "running")
    {:ok, first} = Runs.complete(first["run_dir"], %{"artifact" => "FIRST.md"})

    {:ok, second} =
      Runs.start("second run objective",
        workspace: workspace,
        forked_from: first["id"],
        permission_mode: "deny"
      )

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "runs",
                 "params" => %{"json" => true, "workspace" => workspace}
               }) == 0
      end)

    list = Jason.decode!(output)

    assert list["schema_version"] == "holt_run_list/v1"
    assert Enum.count(list["runs"]) == 2

    first_summary = Enum.find(list["runs"], &(&1["id"] == first["id"]))
    second_summary = Enum.find(list["runs"], &(&1["id"] == second["id"]))

    assert first_summary["status"] == "completed"
    assert first_summary["objective"] == "first run objective"
    assert first_summary["artifact"] == "FIRST.md"
    assert first_summary["latest_answer"] == "First answer"
    assert first_summary["permission_mode"] == "review"
    assert second_summary["objective"] == "second run objective"
    assert second_summary["forked_from"] == first["id"]
    assert second_summary["permission_mode"] == "deny"
    refute Map.has_key?(second_summary, "latest_answer")
  end

  test "fork command starts a branched run from a selected run" do
    %{home: home, workspace: workspace} = tmp_env()
    {:ok, source} = Runs.start("source objective", workspace: workspace)
    source_event_count = length(Runs.events(source["run_dir"]))

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "fork",
                 "params" => %{
                   "home" => home,
                   "workspace" => workspace,
                   "run_ref" => source["id"],
                   "objective" => "alternate objective",
                   "yes" => true
                 }
               }) == 0
      end)

    [forked | _rest] = Runs.list(workspace)

    assert output =~ "Forked from: #{source["id"]}"
    assert forked["objective"] == "alternate objective"
    assert forked["forked_from"] == source["id"]
    assert length(Runs.events(source["run_dir"])) == source_event_count
  end

  test "logs json emits structured run inspection object" do
    %{workspace: workspace} = tmp_env()
    {:ok, run} = Runs.start("json inspect objective", workspace: workspace)
    Runs.append_transcript(run["run_dir"], "user", "json inspect objective")
    Runs.append_transcript(run["run_dir"], "assistant", "Structured JSON answer")

    Runs.append_event(run["run_dir"], "action.approval_requested", %{
      "action_call_id" => "action_call_json_approval",
      "action" => "append",
      "status" => "awaiting_approval",
      "label" => "Appending file NOTES.md",
      "risk" => "write",
      "input_summary" => %{"path" => "NOTES.md"}
    })

    Runs.append_event(run["run_dir"], "action.approval_resolved", %{
      "action_call_id" => "action_call_json_approval",
      "action" => "append",
      "status" => "denied",
      "label" => "Denied Append file",
      "risk" => "write",
      "input_summary" => %{"path" => "NOTES.md"}
    })

    {:ok, _run} = Runs.transition(run["run_dir"], "running")
    {:ok, run} = Runs.complete(run["run_dir"], %{"artifact" => "NEXT_STEPS.md"})

    output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "logs",
                 "params" => %{
                   "json" => true,
                   "workspace" => workspace,
                   "run_ref" => run["id"]
                 }
               }) == 0
      end)

    log = Jason.decode!(output)

    assert log["schema_version"] == "holt_run_log/v1"
    assert log["view"] == "activity"
    assert log["run"]["id"] == run["id"]
    assert log["run"]["objective"] == "json inspect objective"
    assert log["run"]["permission_mode"] == "review"
    assert log["artifact"] == "NEXT_STEPS.md"
    assert log["latest_answer"] == "Structured JSON answer"

    assert [
             %{
               "action_call_id" => "action_call_json_approval",
               "action" => "append",
               "status" => "denied",
               "label" => "Denied Append file",
               "risk" => "write",
               "input_summary" => %{"path" => "NOTES.md"}
             } = approval
           ] = log["approvals"]

    assert is_binary(approval["requested_at"])
    assert is_binary(approval["resolved_at"])
    assert Enum.any?(log["events"], &(&1["type"] == "run.created"))
    assert Enum.map(log["transcript"], & &1["role"]) == ["user", "assistant"]

    transcript_output =
      capture_io(fn ->
        assert Bridge.NativeCommand.run(%{
                 "command" => "logs",
                 "params" => %{
                   "json" => true,
                   "workspace" => workspace,
                   "run_ref" => run["id"],
                   "view" => "transcript"
                 }
               }) == 0
      end)

    transcript_log = Jason.decode!(transcript_output)

    assert transcript_log["schema_version"] == "holt_run_log/v1"
    assert transcript_log["view"] == "transcript"
    assert Enum.map(transcript_log["transcript"], & &1["role"]) == ["user", "assistant"]
  end

  defp tmp_env do
    base = Path.join(System.tmp_dir!(), "holtworks-test-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    workspace = Path.join(base, "workspace")
    File.mkdir_p!(base)

    on_exit(fn -> File.rm_rf!(base) end)

    %{home: home, workspace: workspace}
  end

  defp init_git_workspace(workspace) do
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "--quiet"])
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: System.put_env(key, value)
end
