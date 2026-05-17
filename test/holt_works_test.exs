defmodule HoltWorksTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias HoltWorks.{
    AgentRuntime,
    Bridge,
    Config,
    Env,
    JSON,
    Memory,
    Models,
    Runtime,
    Skills,
    Tasks,
    Tools,
    Workspace
  }

  alias HoltWorks.Runtime.{AgentEvents, Runs, Session, StateMachine}

  test "version is available" do
    assert HoltWorks.version() == "0.1.0"
  end

  test "cli help succeeds" do
    output =
      capture_io(fn ->
        assert HoltWorks.CLI.main(["help"]) == 0
      end)

    assert output =~ "holtworks run"
    assert output =~ "holtworks onboard"
    assert output =~ "holtworks llm test"
  end

  test "unknown cli command returns usage error" do
    output =
      capture_io(:stderr, fn ->
        assert HoltWorks.CLI.main(["nope"]) == 64
      end)

    assert output =~ "Unknown command: nope"
  end

  test "cli runtime contract commands expose provider safety tools and context budget" do
    provider_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main(["tasks", "runtime", "provider", "gpt-5.2"]) == 0
      end)

    assert provider_output =~ "Provider profile: gpt-5.2"
    assert provider_output =~ "Provider: openai"

    safety_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "runtime",
                 "safety",
                 "--task-complexity",
                 "implementation"
               ]) == 0
      end)

    assert safety_output =~ "Safety policy: least_privilege"
    assert safety_output =~ "structured_tool_ingress_only"

    tools_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main(["tasks", "runtime", "tools", "--tool", "get_task"]) == 0
      end)

    assert tools_output =~ "Tool availability: 1"
    assert tools_output =~ "get_task available"

    budget_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "runtime",
                 "context-budget",
                 "--model",
                 "gpt-5.2",
                 "--estimated-input-tokens",
                 "4000"
               ]) == 0
      end)

    assert budget_output =~ "Runtime context budget:"
    assert budget_output =~ "file_backed_task_memory_packet"

    recovery_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "runtime",
                 "recovery",
                 "update_task",
                 "--effect-scope",
                 "task_durable"
               ]) == 0
      end)

    assert recovery_output =~ "Recovery contract:"
    assert recovery_output =~ "compensating_task_update"

    debug_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main(["tasks", "runtime", "debug"]) == 0
      end)

    assert debug_output =~ "Run debugger:"
    assert debug_output =~ "inspect_latest_work_graph"

    learn_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main(["tasks", "runtime", "learn"]) == 0
      end)

    assert learn_output =~ "Meta-learning snapshot:"
    assert learn_output =~ "Recommendations: 0"

    sanitized_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "runtime",
                 "sanitize",
                 "--content",
                 ~s({"command":"run","error":"boom"})
               ]) == 0
      end)

    assert sanitized_output =~ "Local model failed: boom"
  end

  test "onboard creates global config and workspace files" do
    %{home: home, workspace: workspace} = tmp_env()

    output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "onboard",
                 "--yes",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--provider",
                 "local"
               ]) == 0
      end)

    assert output =~ "HoltWorks is ready"
    assert output =~ "Provider check:"
    assert output =~ "Gateway:"
    assert File.exists?(Path.join(home, "config.json"))
    assert File.exists?(Path.join(home, "providers.json"))
    assert File.exists?(Path.join([workspace, ".holtworks", "HOLT.md"]))
    assert File.exists?(Path.join([workspace, ".holtworks", "AGENTS.md"]))
    assert File.exists?(Path.join([workspace, ".holtworks", "TOOLS.md"]))
  end

  test "runtime run records events and writes approved artifact" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, %{run: run, artifact: artifact, output: output}} =
             Runtime.run("inspect this folder and create a short implementation plan",
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert run["status"] == "completed"
    assert artifact["path"] == "NEXT_STEPS.md"
    assert output =~ "# NEXT STEPS"
    assert File.exists?(Path.join(workspace, "NEXT_STEPS.md"))

    events = Runs.events(run["run_dir"])
    assert Enum.any?(events, &(Map.get(&1, "type") == "run.created"))
    assert Enum.any?(events, &(Map.get(&1, "type") == "tool.requested"))
    assert Enum.any?(events, &(Map.get(&1, "type") == "tool.completed"))
  end

  test "runtime executes model tool calls through the action loop" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)
    File.write!(Path.join(workspace, "source.txt"), "tool loop content")
    test_pid = self()

    model_chat = fn _provider, messages, opts ->
      send(test_pid, {:model_call, messages, opts[:tools]})

      if Enum.any?(messages, &(Map.get(&1, "role") == "tool")) do
        {:ok,
         %{
           "provider" => "local",
           "model" => "local-planner",
           "content" => "# NEXT STEPS\n\nRead `source.txt` through the tool loop."
         }}
      else
        {:ok,
         %{
           "provider" => "local",
           "model" => "local-planner",
           "content" => "",
           "tool_calls" => [
             %{
               "id" => "call_read_source",
               "type" => "function",
               "function" => %{
                 "name" => "read_file",
                 "arguments" => Jason.encode!(%{"path" => "source.txt"})
               }
             }
           ]
         }}
      end
    end

    assert {:ok, %{run: run, output: output}} =
             Runtime.run("inspect source file",
               home: home,
               workspace: workspace,
               approval: :always_approve,
               model_chat: model_chat
             )

    assert run["status"] == "completed"
    assert output =~ "source.txt"
    assert File.read!(Path.join(workspace, "NEXT_STEPS.md")) =~ "source.txt"

    assert_received {:model_call, _initial_messages, initial_tools}
    assert Enum.any?(initial_tools, &(get_in(&1, [:function, :name]) == "read_file"))
    assert Enum.any?(initial_tools, &(get_in(&1, [:function, :name]) == "write_file"))
    assert_received {:model_call, tool_messages, _tools}
    assert Enum.any?(tool_messages, &(Map.get(&1, "role") == "tool"))

    events = Runs.events(run["run_dir"])
    assert Enum.any?(events, &(Map.get(&1, "type") == "model.tool_calls"))

    assert Enum.any?(
             events,
             &(Map.get(&1, "type") == "tool.completed" and Map.get(&1, "tool") == "read_file")
           )

    assert {:ok, agent_events} = AgentEvents.list_by_session(run["id"], workspace: workspace)
    event_types = Enum.map(agent_events, & &1["event_type"])
    assert "session_start" in event_types
    assert "user_message" in event_types
    assert "llm_request" in event_types
    assert "llm_response" in event_types
    assert "tool_invocation" in event_types
    assert "tool_result" in event_types
    assert "session_end" in event_types

    assert Enum.map(agent_events, & &1["sequence"]) == Enum.to_list(0..(length(agent_events) - 1))

    assert {:ok, summary} = AgentEvents.get_session_summary(run["id"], workspace: workspace)
    assert summary["status"] == "completed"
    assert summary["event_counts"]["llm_request"] == 2
    assert "read_file" in summary["tools"]

    assert {:ok, tree} = AgentEvents.get_session_tree(run["id"], workspace: workspace)
    nodes = flatten_agent_event_tree(tree["root"])
    assert Enum.any?(nodes, &(&1["type"] == "turn"))
    assert Enum.any?(nodes, &(&1["type"] == "llm"))
    assert Enum.any?(nodes, &(&1["type"] == "tool" and &1["name"] == "Read file"))

    assert %{"ok" => true, "result" => bridge_summary} =
             Bridge.Stdio.handle_request(
               %{"method" => "agent_events/summary", "params" => %{"session_id" => run["id"]}},
               workspace: workspace
             )

    assert bridge_summary["total_events"] == summary["total_events"]
  end

  test "runtime session streams final output and checkpoints status" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, session} =
             Session.start("stream a short local plan",
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    session_id = session["session_id"]

    assert_receive {:stream_chunk, chunk}, 2_000
    assert chunk =~ "# NEXT STEPS"
    assert_receive {:stream_done, done}, 2_000
    assert done =~ "# NEXT STEPS"

    assert {:ok, completed} = Session.status(session_id, workspace: workspace)
    assert completed["status"] == "completed"
    assert completed["accumulated_content_length"] > 0
    assert completed["run_id"]

    assert {:ok, events} = AgentEvents.list_by_session(session_id, workspace: workspace)
    event_types = Enum.map(events, & &1["event_type"])
    assert "session_start" in event_types
    assert "stream_chunk" in event_types
    assert "session_end" in event_types

    assert %{"ok" => true, "result" => bridge_status} =
             Bridge.Stdio.handle_request(
               %{"method" => "agent_sessions/status", "params" => %{"session_id" => session_id}},
               workspace: workspace
             )

    assert bridge_status["status"] == "completed"
  end

  test "runtime session pauses on ask_user tool call and resumes with answer" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    test_pid = self()

    model_chat = fn _provider, messages, _opts ->
      send(test_pid, {:session_model_messages, messages})

      if Enum.any?(messages, &(Map.get(&1, "role") == "tool")) do
        tool_message = Enum.find(messages, &(Map.get(&1, "role") == "tool"))
        assert tool_message["content"] =~ "approved"

        {:ok,
         %{
           "provider" => "local",
           "model" => "local-planner",
           "content" => "# NEXT STEPS\n\nThe user approved continuing."
         }}
      else
        {:ok,
         %{
           "provider" => "local",
           "model" => "local-planner",
           "content" => "",
           "tool_calls" => [
             %{
               "id" => "call_need_user",
               "type" => "function",
               "function" => %{
                 "name" => "ask_user",
                 "arguments" => Jason.encode!(%{"question" => "Continue with the task?"})
               }
             }
           ]
         }}
      end
    end

    assert {:ok, session} =
             Session.start("ask before continuing",
               home: home,
               workspace: workspace,
               approval: :always_approve,
               model_chat: model_chat
             )

    session_id = session["session_id"]

    assert_receive {:awaiting_user, "Continue with the task?"}, 2_000
    assert {:ok, awaiting} = Session.status(session_id, workspace: workspace)
    assert awaiting["status"] == "awaiting_user"
    assert awaiting["awaiting_user"]["tool_call_id"] == "call_need_user"

    assert {:ok, running} = Session.respond(session_id, "approved", workspace: workspace)
    assert running["status"] == "running"
    assert_receive {:user_response, "approved"}, 1_000
    assert_receive {:stream_chunk, chunk}, 2_000
    assert chunk =~ "user approved"
    assert_receive {:stream_done, done}, 2_000
    assert done =~ "user approved"

    assert_received {:session_model_messages, _initial_messages}
    assert_received {:session_model_messages, tool_messages}
    assert Enum.any?(tool_messages, &(Map.get(&1, "role") == "tool"))

    assert {:ok, completed} = Session.status(session_id, workspace: workspace)
    assert completed["status"] == "completed"

    assert {:ok, events} = AgentEvents.list_by_session(session_id, workspace: workspace)
    event_types = Enum.map(events, & &1["event_type"])
    assert "awaiting_user" in event_types
    assert "user_response" in event_types
    assert "stream_chunk" in event_types
  end

  test "runtime session pauses on ask_user_question tool call and resumes with answer" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    test_pid = self()

    model_chat = fn _provider, messages, _opts ->
      send(test_pid, {:question_model_messages, messages})

      if Enum.any?(messages, &(Map.get(&1, "role") == "tool")) do
        tool_message = Enum.find(messages, &(Map.get(&1, "role") == "tool"))
        assert tool_message["name"] == "ask_user_question"
        assert tool_message["content"] =~ "go"

        {:ok,
         %{
           "provider" => "local",
           "model" => "local-planner",
           "content" => "# NEXT STEPS\n\nContinue with the selected path."
         }}
      else
        {:ok,
         %{
           "provider" => "local",
           "model" => "local-planner",
           "content" => "",
           "tool_calls" => [
             %{
               "id" => "call_question",
               "type" => "function",
               "function" => %{
                 "name" => "ask_user_question",
                 "arguments" =>
                   Jason.encode!(%{
                     "question" => "Choose a path",
                     "options" => [%{"label" => "Go", "value" => "go"}]
                   })
               }
             }
           ]
         }}
      end
    end

    assert {:ok, session} =
             Session.start("ask a structured question",
               home: home,
               workspace: workspace,
               approval: :always_approve,
               model_chat: model_chat
             )

    session_id = session["session_id"]

    assert_receive {:awaiting_user, "Choose a path"}, 2_000
    assert {:ok, awaiting} = Session.status(session_id, workspace: workspace)
    assert awaiting["status"] == "awaiting_user"
    assert awaiting["awaiting_user"]["tool_call_id"] == "call_question"

    assert {:ok, running} = Session.respond(session_id, "go", workspace: workspace)
    assert running["status"] == "running"
    assert_receive {:user_response, "go"}, 1_000
    assert_receive {:stream_done, done}, 2_000
    assert done =~ "selected path"

    assert_received {:question_model_messages, _initial_messages}
    assert_received {:question_model_messages, tool_messages}
    assert Enum.any?(tool_messages, &(Map.get(&1, "role") == "tool"))
  end

  test "runtime blocks when approval is denied" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, %{run: run, artifact: nil}} =
             Runtime.run("write a plan",
               home: home,
               workspace: workspace,
               approval: :always_deny
             )

    assert run["status"] == "blocked"
    refute File.exists?(Path.join(workspace, "NEXT_STEPS.md"))
  end

  test "runtime blocks denied model write tool calls" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    model_chat = fn _provider, _messages, _opts ->
      {:ok,
       %{
         "provider" => "local",
         "model" => "local-planner",
         "content" => "",
         "tool_calls" => [
           %{
             "id" => "call_write_notes",
             "type" => "function",
             "function" => %{
               "name" => "write_file",
               "arguments" => Jason.encode!(%{"path" => "notes.txt", "content" => "denied write"})
             }
           }
         ]
       }}
    end

    assert {:ok, %{run: run, artifact: nil, output: nil}} =
             Runtime.run("write notes",
               home: home,
               workspace: workspace,
               approval: :always_deny,
               model_chat: model_chat
             )

    assert run["status"] == "blocked"
    assert run["blocker_code"] == "approval_denied"
    refute File.exists?(Path.join(workspace, "notes.txt"))

    events = Runs.events(run["run_dir"])

    assert Enum.any?(
             events,
             &(Map.get(&1, "type") == "tool.failed" and
                 Map.get(&1, "tool") == "write_file" and
                 Map.get(&1, "reason") == "approval_denied")
           )
  end

  test "resume starts a continuation run from the prior objective" do
    %{home: home, workspace: workspace} = tmp_env()

    assert {:ok, %{run: original}} =
             Runtime.run("inspect this folder",
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert {:ok, %{run: resumed}} =
             Runtime.resume(original["id"],
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert resumed["status"] == "completed"
    assert resumed["resumed_from"] == original["id"]
    assert resumed["objective"] == original["objective"]
  end

  test "action catalog exposes transport-neutral provider-filtered tools" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} = Tasks.create(%{"title" => "Catalog task"}, workspace: workspace)

    context = %{
      "task_ref" => task["ref"],
      "action_provider_ids" => ["workspace"],
      "excluded_actions" => ["write_file"]
    }

    catalog = Tasks.action_catalog(context, workspace: workspace)
    names = Enum.map(catalog, & &1["name"])
    assert "read_file" in names
    refute "write_file" in names
    refute "add_comment" in names

    read_entry = Enum.find(catalog, &(&1["name"] == "read_file"))
    assert read_entry["schema_version"] == "holtworks_tool_catalog_entry/v1"
    assert read_entry["surface"] == "agent"
    assert read_entry["source"] == "action"
    assert read_entry["provider_id"] == "workspace"
    assert read_entry["input_schema"]["type"] == "object"

    openai_tools = Tasks.agent_tool_definitions(context, workspace: workspace)

    assert Enum.any?(
             openai_tools,
             &(get_in(&1, ["function", "name"]) == "read_file" and
                 get_in(&1, ["function", "parameters", "type"]) == "object")
           )

    assert [%{"id" => "workspace", "tool_count" => tool_count}] =
             Tasks.action_provider_metadata(context, workspace: workspace)

    assert tool_count > 0

    assert [%{"provider_id" => "workspace", "content" => prompt_section}] =
             Tasks.action_provider_prompt_sections(context, workspace: workspace)

    assert prompt_section =~ "Workspace tools"

    assert {:ok, execution} =
             Tasks.dispatch_agent_tool(
               "add_comment",
               %{"body" => "catalog dispatch"},
               %{"task_ref" => task["ref"]},
               workspace: workspace
             )

    assert execution["status"] == "ok"
    assert [%{"body" => "catalog dispatch"}] = get_in(execution, ["result", "comments"])

    assert %{"ok" => true, "result" => bridge_catalog} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "agent_tools/catalog",
                 "params" => context
               },
               workspace: workspace
             )

    assert Enum.any?(bridge_catalog, &(&1["name"] == "read_file"))
  end

  test "search_web action records structured research claims" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    web_search = fn %{"query" => "holtworks runtime"}, _opts ->
      {:ok,
       %{
         "answer" => "HoltWorks is a local agent runtime.",
         "results" => [
           %{
             "title" => "HoltWorks docs",
             "url" => "https://holtworks.ai/docs/runtime",
             "content" => "Runtime documentation for HoltWorks."
           }
         ]
       }}
    end

    assert {:ok, execution} =
             Tasks.execute_action(
               "search_web",
               %{
                 "query" => "holtworks runtime",
                 "save_research_claim" => true,
                 "claim" => "HoltWorks has local agent runtime documentation.",
                 "source_type" => "official_docs",
                 "version_applies" => "2026-05-17",
                 "confidence" => 0.82
               },
               workspace: workspace,
               approval: :always_approve,
               web_search: web_search
             )

    assert execution["status"] == "ok"
    assert execution["tool_name"] == "search_web"
    assert execution["result"]["text"] =~ "## Search Results"
    assert execution["result"]["research_claim_saved"] == true

    claim = execution["result"]["research_claim"]
    assert claim["schema_version"] == "holtworks_research_claim/v1"
    assert claim["source"]["tool"] == "search_web"
    assert claim["source"]["query"] == "holtworks runtime"
    assert claim["source"]["urls"] == ["https://holtworks.ai/docs/runtime"]
    assert claim["source_type"] == "official_docs"
    assert claim["claim"] == "HoltWorks has local agent runtime documentation."
    assert claim["claim_origin"] == "agent_supplied"
    assert claim["version_applies"] == "2026-05-17"
    assert claim["confidence"] == 0.82
    assert claim["evidence"]["result_count"] == 1

    assert [stored_claim] = Tasks.research_claims(workspace: workspace)
    assert stored_claim["id"] == claim["id"]

    assert %{"ok" => true, "result" => [bridge_claim]} =
             Bridge.Stdio.handle_request(%{"method" => "research_claims/list"},
               workspace: workspace
             )

    assert bridge_claim["id"] == claim["id"]

    catalog =
      Tasks.action_catalog(%{"action_provider_ids" => ["workspace"]}, workspace: workspace)

    search_entry = Enum.find(catalog, &(&1["name"] == "search_web"))
    assert search_entry["input_schema"]["required"] == ["query"]
    assert get_in(search_entry, ["input_schema", "properties", "source_type", "enum"]) != []
  end

  test "search_web requires an explicit claim when saving research metadata" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    web_search = fn _args, _opts ->
      flunk("search provider should not run when claim metadata is invalid")
    end

    assert {:error, execution} =
             Tasks.execute_action(
               "search_web",
               %{"query" => "holtworks", "save_research_claim" => true},
               workspace: workspace,
               approval: :always_approve,
               web_search: web_search
             )

    assert execution["status"] == "error"
    assert execution["reason"] =~ "claim"
    assert Tasks.research_claims(workspace: workspace) == []
  end

  test "task store creates updates comments specs and verification reports" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Port Inktrail task flow",
                 "priority" => "high",
                 "assignees" => ["default"]
               },
               workspace: workspace
             )

    assert task["ref"] == "HW-01"
    assert task["status"] == "todo"
    assert [%{"ref" => "HW-01"}] = Tasks.list(workspace: workspace, status: "todo")

    assert {:ok, updated} =
             Tasks.update(task["ref"], %{"status" => "in_progress"}, workspace: workspace)

    assert updated["status"] == "in_progress"

    assert {:ok, commented} =
             Tasks.add_comment(task["ref"], "Keep lifecycle state structured.",
               workspace: workspace
             )

    assert [%{"body" => "Keep lifecycle state structured."}] = commented["comments"]

    assert {:ok, spec} =
             Tasks.save_spec(
               task["ref"],
               %{
                 "kind" => "decision",
                 "title" => "Local task store",
                 "content" => "Use workspace-local task records and specs."
               },
               workspace: workspace
             )

    assert spec["kind"] == "decision"
    assert File.exists?(Path.join(workspace, spec["path"]))

    assert {:ok, %{task: verified, report: report, spec: report_spec}} =
             Tasks.route_verification(
               task["ref"],
               %{
                 "summary" => "All structured checks passed.",
                 "checks" => [%{"name" => "tests", "status" => "passed"}]
               },
               workspace: workspace
             )

    assert verified["status"] == "done"
    assert report["decision"] == "done"
    assert report["route"]["can_finish"] == true
    assert report_spec["kind"] == "verification_report"

    assert Enum.any?(
             verified["comments"],
             &match?(%{"metadata" => %{"kind" => "verification_route"}}, &1)
           )
  end

  test "verification risk flags keep passed work waiting for human review" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Review sensitive work"}, workspace: workspace)

    assert {:ok, %{task: reviewed, report: report}} =
             Tasks.route_verification(
               task["ref"],
               %{
                 "summary" => "Tests passed, but billing behavior changed.",
                 "checks" => [%{"name" => "tests", "status" => "passed"}],
                 "risk_flags" => ["billing"]
               },
               workspace: workspace
             )

    assert reviewed["status"] == "waiting"
    assert report["decision"] == "waiting"
    assert report["route"]["can_finish"] == false
    assert report["route"]["reason"] == "risk_review_required"
  end

  test "evidence contracts gate verification on structured proof requirements" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Evidence-gated verification"}, workspace: workspace)

    assert {:ok, _contract_spec} =
             Tasks.save_spec(
               task["ref"],
               %{
                 "kind" => "workflow_contract",
                 "title" => "Evidence contract",
                 "content" => "Evidence requirements are stored in metadata.",
                 "metadata" => %{
                   "evidence_contract" => %{
                     "required_check_groups" => [
                       %{"group_id" => "regression", "any_of" => ["regression_check"]}
                     ],
                     "changed_files_required" => true,
                     "command_evidence_required" => true
                   }
                 }
               },
               workspace: workspace
             )

    assert {:ok, contract} = Tasks.evidence_contract(task["ref"], %{}, workspace: workspace)
    assert contract["changed_files_required"] == true

    assert {:ok, %{task: waiting, report: incomplete_report, gateway: gateway}} =
             Tasks.route_verification(
               task["ref"],
               %{
                 "summary" => "A generic check passed, but required evidence is missing.",
                 "checks" => [%{"name" => "tests", "status" => "passed"}]
               },
               workspace: workspace
             )

    assert waiting["status"] == "waiting"
    assert incomplete_report["route"]["can_finish"] == false
    assert incomplete_report["route"]["reason"] == "evidence_contract_not_satisfied"
    assert gateway["evidence_evaluation"]["satisfied"] == false

    assert evidence_gap_codes(incomplete_report) == [
             "missing_check_group",
             "changed_files_required",
             "command_evidence_required"
           ]

    assert {:ok, %{task: done, report: complete_report}} =
             Tasks.route_verification(
               task["ref"],
               %{
                 "summary" => "Required evidence passed.",
                 "checks" => [
                   %{
                     "name" => "regression suite",
                     "check_type" => "regression_check",
                     "status" => "passed",
                     "command" => "mix test"
                   }
                 ],
                 "changed_files" => ["lib/holt_works/tasks.ex"],
                 "evidence" => ["mix test"]
               },
               workspace: workspace
             )

    assert done["status"] == "done"
    assert complete_report["route"]["can_finish"] == true
    assert complete_report["evidence_evaluation"]["satisfied"] == true
  end

  test "task labels links comment deletion and spec reads match local action parity" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, first} =
             Tasks.create(
               %{
                 "title" => "First task",
                 "labels" => ["backend"],
                 "estimate" => 3
               },
               workspace: workspace
             )

    assert {:ok, second} =
             Tasks.create(%{"title" => "Second task"}, workspace: workspace)

    assert [%{"name" => "backend", "color" => "#2563eb"}] = first["labels"]
    assert first["estimate"] == 3

    assert {:ok, labeled} =
             Tasks.add_label(first["ref"], %{"name" => "frontend", "color" => "#16a34a"},
               workspace: workspace
             )

    assert Enum.any?(labeled["labels"], &(&1["name"] == "frontend"))

    assert {:ok, unlabeled} =
             Tasks.remove_label(first["ref"], "backend", workspace: workspace)

    refute Enum.any?(unlabeled["labels"], &(&1["name"] == "backend"))

    assert {:ok, linked} =
             Tasks.add_link(first["ref"], second["ref"], "depends_on", workspace: workspace)

    assert [%{"target_ref" => "HW-02", "type" => "depends_on"} = link] = linked["links"]

    assert {:error, :duplicate_link} =
             Tasks.add_link(first["ref"], second["ref"], "relates_to", workspace: workspace)

    assert {:error, :self_link} =
             Tasks.add_link(first["ref"], first["ref"], "depends_on", workspace: workspace)

    assert {:ok, unlinked} =
             Tasks.remove_link(first["ref"], link["id"], workspace: workspace)

    assert unlinked["links"] == []

    assert {:ok, commented} =
             Tasks.add_comment(first["ref"], "temporary comment", workspace: workspace)

    [%{"id" => comment_id}] = commented["comments"]

    assert {:ok, without_comment} =
             Tasks.delete_comment(first["ref"], comment_id, workspace: workspace)

    assert without_comment["comments"] == []

    assert {:error, :comment_not_found} =
             Tasks.delete_comment(first["ref"], comment_id, workspace: workspace)

    assert {:ok, spec} =
             Tasks.save_spec(
               first["ref"],
               %{
                 "kind" => "handoff",
                 "title" => "Handoff",
                 "content" => "Detailed handoff content."
               },
               workspace: workspace
             )

    assert {:ok, [listed_spec]} =
             Tasks.list_specs(first["ref"],
               workspace: workspace,
               kind: "handoff",
               include_content: true
             )

    assert listed_spec["id"] == spec["id"]
    assert listed_spec["content"] == "Detailed handoff content."

    assert {:ok, fetched_spec} =
             Tasks.get_spec(spec["id"], workspace: workspace, task_ref: first["ref"])

    assert fetched_spec["content"] == "Detailed handoff content."

    assert {:error, :spec_task_mismatch} =
             Tasks.get_spec(spec["id"], workspace: workspace, task_ref: second["ref"])

    assert {:ok, memory} =
             Tasks.save_teammate_memory(
               first["ref"],
               %{
                 "kind" => "preference_signal",
                 "title" => "Prefers structured verification",
                 "observed_pattern" => "The owner expects explicit check evidence.",
                 "source_spec_ids" => [spec["id"]],
                 "memory_scope" => "team",
                 "portability" => "org_confidential"
               },
               workspace: workspace
             )

    assert memory["kind"] == "preference_signal"

    assert {:ok, runtime_text} =
             Tasks.load_teammate_runtime(first["ref"], workspace: workspace)

    assert runtime_text =~ "# Agent teammate runtime"
    assert runtime_text =~ "Prefers structured verification"

    assert {:ok, memory_artifact} =
             Tasks.read_memory_artifact(memory["id"], workspace: workspace)

    assert memory_artifact["content"] =~ "The owner expects explicit check evidence."
  end

  test "task agent work links a runtime run and waits for verification" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Inspect workspace"}, workspace: workspace)

    assert {:ok, %{task: after_run, run: run, agent_work: work, output: output}} =
             Tasks.start_agent_work(
               task["ref"],
               %{"message" => "Create the implementation plan artifact."},
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert output =~ "# NEXT STEPS"
    assert run["status"] == "completed"
    assert after_run["status"] == "waiting"
    assert work["status"] == "awaiting_verification"
    assert work["run_id"] == run["id"]
    assert work["agent_run_id"]
    assert work["liveness"]["status"] == "inactive"

    assert [agent_run] = Tasks.agent_runs(workspace: workspace)
    assert agent_run["work_id"] == work["id"]
    assert agent_run["run_id"] == run["id"]
    assert agent_run["lifecycle_state"] == "awaiting_verification"
    assert agent_run["objective_status"] == "needs_verification"
    assert agent_run["agent_loop"]["schema_version"] == "holtworks_agent_loop/v1"
    assert agent_run["agent_loop"]["mode"] == "continuous_until_verified"

    assert {:ok, fetched} = Tasks.get(task["ref"], workspace: workspace)

    assert [%{"agent_run" => %{"lifecycle_state" => "awaiting_verification"}}] =
             fetched["agent_work"]
  end

  test "process wake records terminal events and queues same-task continuation packet" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Process wake task"}, workspace: workspace)

    assert {:ok, %{agent_work: work}} =
             Tasks.start_agent_work(
               task["ref"],
               %{"message" => "Create a plan before process wake."},
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert [agent_run] = Tasks.agent_runs(workspace: workspace)

    assert {:ok, started} =
             Tasks.record_process_started(
               %{
                 "managed_process_id" => "proc1",
                 "status" => "running",
                 "wait_for_exit" => true
               },
               %{"agent_run_id" => agent_run["id"]},
               workspace: workspace
             )

    assert started["action"] == "process_recorded"
    assert started["event_kind"] == "process.started"

    assert {:ok, wake} =
             Tasks.notify_process_terminal(
               %{
                 "managed_process_id" => "proc1",
                 "status" => "exited",
                 "exit_code" => 0,
                 "wait_for_exit" => true
               },
               %{"agent_run_id" => agent_run["id"]},
               workspace: workspace
             )

    assert wake["action"] == "wake_queued"
    assert wake["reason"] == "process_exited"
    assert wake["process_wake_packet"]["schema_version"] == "holtworks_agent_process_wake/v1"
    assert wake["process_wake_packet"]["previous_agent_run_id"] == agent_run["id"]

    assert {:ok, updated_task} = Tasks.get(task["ref"], workspace: workspace)
    assert [updated_work] = updated_task["agent_work"]
    assert updated_work["id"] == work["id"]
    assert updated_work["process_wake_status"] == "wake_queued"
    assert updated_work["process_wake_packet"]["process"]["exit_code"] == 0

    assert [updated_run] = Tasks.agent_runs(workspace: workspace)
    assert updated_run["process_wake_status"] == "wake_queued"
    assert updated_run["lifecycle_state"] == "needs_continuation"

    assert %{"ok" => true, "result" => stdio_started} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "record_process_started",
                 "params" => %{
                   "agent_run_id" => agent_run["id"],
                   "managed_process_id" => "proc2"
                 }
               },
               workspace: workspace
             )

    assert stdio_started["event_kind"] == "process.started"

    cli_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "process",
                 "started",
                 agent_run["id"],
                 "--workspace",
                 workspace,
                 "--managed-process-id",
                 "proc3"
               ]) == 0
      end)

    assert cli_output =~ "Process event: process_recorded"

    Tasks.agent_run_events(workspace: workspace)
    |> Enum.map(& &1["type"])
    |> assert_event_types(["process.started", "process.exited", "agent_run.wake_queued"])
  end

  test "agent run event ledger records structured events and replays by agent" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Agent run ledger task"}, workspace: workspace)

    assert {:ok, %{agent_work: _work}} =
             Tasks.start_agent_work(
               task["ref"],
               %{"message" => "Create structured run events."},
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert [agent_run] = Tasks.agent_runs(workspace: workspace)

    assert {:ok, _run, narration} =
             Tasks.record_agent_run_narration(
               agent_run["id"],
               %{"body" => "Planner narration", "idempotency_key" => "narration-1"},
               workspace: workspace
             )

    assert {:duplicate, _run, duplicate_narration} =
             Tasks.record_agent_run_narration(
               agent_run["id"],
               %{"body" => "Planner narration", "idempotency_key" => "narration-1"},
               workspace: workspace
             )

    assert duplicate_narration["id"] == narration["id"]

    assert {:ok, _run, plan_event} =
             Tasks.record_agent_run_plan_contract(
               agent_run["id"],
               %{
                 "schema_version" => "holtworks_plan_contract/v1",
                 "plan_id" => "plan-1",
                 "steps" => [%{"id" => "step-1", "status" => "planned"}]
               },
               workspace: workspace
             )

    assert plan_event["kind"] == "plan.contract"

    assert {:ok, _run, tool_event} =
             Tasks.record_agent_run_tool_event(
               agent_run["id"],
               %{
                 "tool_name" => "update_task",
                 "tool_call_id" => "tool-call-1",
                 "result_status" => "ok",
                 "result_preview" => "Updated task state",
                 "action_runtime_envelope" => %{"envelope_id" => "env-1"}
               },
               workspace: workspace
             )

    assert tool_event["metadata"]["schema_version"] == "holtworks_agent_run_tool_event/v1"
    assert tool_event["metadata"]["effective_work"] == true

    assert {:ok, _run, child_contract_event} =
             Tasks.record_agent_run_child_contract(
               agent_run["id"],
               %{"child_agent_id" => "agent-child-1", "role" => "worker"},
               workspace: workspace
             )

    assert child_contract_event["kind"] == "child_agent.contract"

    assert {:ok, _run, child_completion_event} =
             Tasks.record_agent_run_child_completion(
               agent_run["id"],
               %{"child_agent_id" => "agent-child-1", "child_run_id" => "child-run-1"},
               workspace: workspace
             )

    assert child_completion_event["kind"] == "child_agent.completed"

    assert {:ok, _run, objective_event} =
             Tasks.record_agent_run_objective_evaluation(
               agent_run["id"],
               %{"route" => %{"can_finish" => true}, "verification_status" => "passed"},
               workspace: workspace
             )

    assert objective_event["kind"] == "objective.evaluated"

    assert {:ok, _run, continuation_event} =
             Tasks.record_agent_run_continuation_packet(
               agent_run["id"],
               %{
                 "previous_agent_run_id" => agent_run["id"],
                 "continuation_depth" => 1,
                 "source" => "test"
               },
               workspace: workspace
             )

    assert continuation_event["kind"] == "agent_run.continuation_packet"

    assert {:ok, events} = Tasks.agent_run_event_log(agent_run["id"], workspace: workspace)

    events
    |> Enum.map(& &1["kind"])
    |> assert_event_types([
      "agent.narration",
      "plan.contract",
      "tool.completed",
      "child_agent.contract",
      "child_agent.completed",
      "objective.evaluated",
      "agent_run.continuation_packet"
    ])

    assert [tool_search_event] =
             Tasks.agent_run_events_by_agent(
               agent_run["agent_id"],
               %{"kind" => "tool.completed"},
               workspace: workspace
             )

    assert tool_search_event["metadata"]["tool_call_id"] == "tool-call-1"

    assert {:ok, replay} =
             Tasks.agent_run_replay(agent_run["agent_id"], agent_run["id"], workspace: workspace)

    assert replay["schema_version"] == "holtworks_agent_run_replay/v1"
    assert replay["event_count"] == length(events)

    assert %{"ok" => true, "result" => %{"action" => "event_recorded", "event" => stdio_event}} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "record_tool_event",
                 "params" => %{
                   "agent_run_id" => agent_run["id"],
                   "tool_name" => "save_task_spec",
                   "tool_call_id" => "tool-call-2",
                   "result_status" => "ok"
                 }
               },
               workspace: workspace
             )

    assert stdio_event["kind"] == "tool.completed"

    cli_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "runs",
                 "events",
                 agent_run["id"],
                 "--workspace",
                 workspace
               ]) == 0
      end)

    assert cli_output =~ "Agent run events:"
    assert cli_output =~ "tool.completed"
  end

  test "task graphs gate work on dependency completion and structured verification" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} = Tasks.create(%{"title" => "Graph gated task"}, workspace: workspace)

    assert {:ok, graph} = Tasks.create_task_graph(task["ref"], %{}, workspace: workspace)

    assert graph["schema_version"] == "holtworks_task_graph/v1"
    assert graph_node(graph, "plan")["status"] == "scheduled"
    assert graph_node(graph, "work")["status"] == "pending"
    assert graph_node(graph, "verify")["status"] == "pending"

    assert graph["mission_control"]["status"] == "blocked"

    assert "required_node_incomplete" in blocker_codes(graph)
    assert "verification_gate_not_satisfied" in blocker_codes(graph)

    assert {:ok, planned} =
             Tasks.complete_task_graph_node(graph["id"], "plan", %{"summary" => "Plan ready."},
               workspace: workspace
             )

    assert graph_node(planned, "plan")["status"] == "done"
    assert graph_node(planned, "work")["status"] == "scheduled"

    assert {:ok, worked} =
             Tasks.complete_task_graph_node(graph["id"], "work", %{"summary" => "Work ready."},
               workspace: workspace
             )

    assert graph_node(worked, "verify")["status"] == "scheduled"
    assert worked["mission_control"]["can_finish"] == false

    assert {:ok, %{report: report, task_graph: verified_graph, task_graph_gate: gate}} =
             Tasks.route_verification(
               task["ref"],
               %{
                 "graph_id" => graph["id"],
                 "summary" => "Graph checks passed.",
                 "checks" => [%{"name" => "tests", "status" => "passed"}]
               },
               workspace: workspace
             )

    assert report["route"]["can_finish"] == true
    assert graph_node(verified_graph, "verify")["status"] == "done"
    assert graph_node(verified_graph, "integrate")["status"] == "scheduled"
    assert gate["status"] == "approved"
    assert gate["can_finish"] == true

    workspace
    |> Tasks.task_graph_events_path()
    |> JSON.read_jsonl()
    |> Enum.map(& &1["type"])
    |> assert_event_types([
      "task_graph.created",
      "task_graph.node_completed",
      "task_graph.verification_recorded"
    ])
  end

  test "graph-bound agent work updates the work node before verification" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Graph-bound agent work"}, workspace: workspace)

    assert {:ok, graph} = Tasks.create_task_graph(task["ref"], %{}, workspace: workspace)

    assert {:ok, _planned} =
             Tasks.complete_task_graph_node(graph["id"], "plan", %{"summary" => "Plan ready."},
               workspace: workspace
             )

    assert {:ok, result} =
             Tasks.start_agent_work(
               task["ref"],
               %{
                 "message" => "Run graph-bound work.",
                 "graph_id" => graph["id"],
                 "node_key" => "work"
               },
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert result[:agent_work]["task_graph_id"] == graph["id"]
    assert result[:agent_work]["task_graph_node_key"] == "work"
    assert graph_node(result[:task_graph], "work")["status"] == "done"
    assert graph_node(result[:task_graph], "verify")["status"] == "scheduled"
    assert result[:task_graph_gate]["can_finish"] == false
  end

  test "verifier routing creates a bounded verifier contract and records it on graph" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Verifier route task",
                 "assignees" => [
                   %{"id" => "builder_agent", "kind" => "agent", "work_role" => "worker"},
                   %{"id" => "verifier_agent", "kind" => "agent", "work_role" => "verifier"}
                 ]
               },
               workspace: workspace
             )

    assert {:ok, graph} = Tasks.create_task_graph(task["ref"], %{}, workspace: workspace)

    assert {:ok, %{route: route, task_graph: routed_graph}} =
             Tasks.plan_verifier_route(task["ref"], %{"graph_id" => graph["id"]},
               workspace: workspace
             )

    assert route["schema_version"] == "holtworks_verifier_routing/v1"
    assert route["status"] == "requested"
    assert route["target_agent_id"] == "verifier_agent"
    assert route["child_agent_contract"]["authority_boundary"]["may_delegate_further"] == false

    assert route["child_agent_contract"]["job_contract"]["gate_tool"] ==
             "route_verification_review"

    assert route["start_agent_work_params"]["graph_id"] == graph["id"]
    assert route["start_agent_work_params"]["node_key"] == "verify"
    assert routed_graph["verifier_route"]["route_id"] == route["route_id"]

    workspace
    |> Tasks.task_graph_events_path()
    |> JSON.read_jsonl()
    |> Enum.map(& &1["type"])
    |> assert_event_types(["task_graph.verifier_route_planned"])
  end

  test "verifier operations assign dispatch and calibrate independent verifiers" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)
    opts = [workspace: workspace]

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Verifier operation task",
                 "assignees" => [
                   %{"id" => "agent_worker", "kind" => "agent", "work_role" => "worker"},
                   %{"id" => "agent_verify", "kind" => "agent", "work_role" => "verifier"}
                 ]
               },
               opts
             )

    assert {:ok, graph} = Tasks.create_task_graph(task["ref"], %{}, opts)

    assert {:ok, contract} =
             Tasks.verification_contract(task["ref"], %{"graph_id" => graph["id"]}, opts)

    assert contract["schema_version"] == "holtworks_verification_contract/v1"
    assert contract["required"] == true
    assert contract["gate_tool"] == "route_verification_review"
    assert contract["artifact_kinds"] == ["verification_report"]

    assignment_attrs = %{
      "graph_id" => graph["id"],
      "actor_agent_ids" => ["agent_worker"]
    }

    assert {:ok, assignment} =
             Tasks.verifier_assignment(task["ref"], assignment_attrs, opts)

    assert assignment["schema_version"] == "holtworks_verifier_assignment/v1"
    assert assignment["assignment_result"] == "assigned"
    assert assignment["actor_agent_ids"] == ["agent_worker"]
    assert assignment["selected_verifier"]["agent_id"] == "agent_verify"
    assert assignment["selected_verifier"]["execution_mode"] == "persisted_agent"

    worker_candidate =
      Enum.find(assignment["eligible_verifiers"], &(&1["agent_id"] == "agent_worker"))

    assert worker_candidate["eligible"] == false
    assert worker_candidate["independence_status"] == "same_actor"

    assert {:ok, dispatch} =
             Tasks.verifier_dispatch(task["ref"], assignment_attrs, opts)

    assert dispatch["schema_version"] == "holtworks_verifier_dispatch/v1"
    assert dispatch["status"] == "claimed"
    assert dispatch["target_agent_id"] == "agent_verify"
    assert dispatch["source"] == "verifier_dispatcher"
    assert dispatch["permissions"]["may_mark_parent_done"] == false
    assert dispatch["child_agent_contract"]["child"]["work_role"] == "verifier"
    assert dispatch["child_agent_contract"]["authority_boundary"]["may_delegate_further"] == false
    assert dispatch["start_agent_work_params"]["source"] == "verifier_dispatcher"
    assert dispatch["start_agent_work_params"]["node_key"] == "verify"
    assert dispatch["start_agent_work_params"]["agent_ids"] == ["agent_verify"]

    assert {:ok, calibration} =
             Tasks.verifier_calibration(
               task["ref"],
               %{
                 "graph_id" => graph["id"],
                 "verifier_assignment" => assignment,
                 "verifier_agent_id" => "agent_verify",
                 "later_outcome" => "matched",
                 "evaluation" => %{
                   "completion_decision" => "auto_finish_allowed",
                   "verification_status" => "passed",
                   "can_finish" => true
                 }
               },
               opts
             )

    assert calibration["schema_version"] == "holtworks_verifier_calibration/v1"
    assert calibration["verifier_agent_id"] == "agent_verify"
    assert calibration["verdict"] == "approved"
    assert calibration["later_outcome"] == "matched"
    assert calibration["recommended_future_assignment_policy"] == "keep_current_verifier_eligible"

    assert [stored_calibration] = Tasks.verifier_calibrations(opts)
    assert stored_calibration["calibration_id"] == calibration["calibration_id"]

    assert {:ok, weighted_assignment} =
             Tasks.verifier_assignment(task["ref"], assignment_attrs, opts)

    assert get_in(weighted_assignment, ["selected_verifier", "agent_id"]) == "agent_verify"

    verifier_candidate =
      Enum.find(weighted_assignment["eligible_verifiers"], &(&1["agent_id"] == "agent_verify"))

    assert get_in(verifier_candidate, ["verifier_quality", "matched_count"]) == 1
    assert get_in(verifier_candidate, ["verifier_quality", "sample_count"]) == 1

    assert %{"ok" => true, "result" => stdio_assignment} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "assign_verifier",
                 "params" => Map.put(assignment_attrs, "task_id", task["ref"])
               },
               opts
             )

    assert stdio_assignment["schema_version"] == "holtworks_verifier_assignment/v1"
    assert stdio_assignment["selected_verifier"]["agent_id"] == "agent_verify"

    assert %{"ok" => true, "result" => stdio_dispatch} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "dispatch_verifier",
                 "params" => Map.put(assignment_attrs, "task_id", task["ref"])
               },
               opts
             )

    assert stdio_dispatch["schema_version"] == "holtworks_verifier_dispatch/v1"
    assert stdio_dispatch["target_agent_id"] == "agent_verify"
  end

  test "agent runtime facade exposes provider safety tool and context contracts" do
    tools =
      AgentRuntime.tool_availability(%{
        "tool_names" => ["get_task", "write_file", "unknown_tool"],
        "approval_status" => "denied"
      })

    read_tool = Enum.find(tools, &(&1["name"] == "get_task"))
    write_tool = Enum.find(tools, &(&1["name"] == "write_file"))
    unknown_tool = Enum.find(tools, &(&1["name"] == "unknown_tool"))

    assert read_tool["schema_version"] == "holtworks_tool_availability/v1"
    assert read_tool["available"] == true
    assert write_tool["available"] == false
    assert write_tool["unavailable_reason"] == "approval_required"
    assert unknown_tool["available"] == false
    assert unknown_tool["unavailable_reason"] == "tool_not_registered"

    doctor = AgentRuntime.doctor(%{"tool_names" => ["get_task", "unknown_tool"]})
    assert doctor["schema_version"] == "holtworks_agent_runtime_doctor/v1"
    assert doctor["status"] == "degraded"

    provider = AgentRuntime.provider_profile("gpt-5.2", %{})
    assert provider["schema_version"] == "holtworks_provider_profile/v1"
    assert provider["provider"] == "openai"
    assert provider["runtime_kind"] == "hosted_llm"
    assert provider["context_window"] == 128_000
    assert provider["requires_api_key"] == true

    safety =
      AgentRuntime.safety_policy(%{
        "task_complexity" => "implementation",
        "max_attempts" => 3,
        "max_continuation_depth" => 2
      })

    assert safety["schema_version"] == "holtworks_safety_policy/v1"
    assert safety["permission_mode"] == "least_privilege"
    assert safety["command_policy"] == "structured_tool_ingress_only"
    assert safety["sandbox_policy"] == "required_for_code_or_services"
    assert safety["retry_policy"]["max_attempts"] == 3
    assert safety["retry_policy"]["max_continuation_depth"] == 2

    budget =
      AgentRuntime.context_budget(%{
        "policy" => %{"max_total_tokens" => 64_000, "max_tool_calls" => 40},
        "provider_profile" => provider,
        "run_token_budget" => 32_000,
        "estimated_input_tokens" => 96_000
      })

    assert budget["schema_version"] == "holtworks_context_budget/v1"
    assert budget["provider_context_window"] == 128_000
    assert budget["compression"]["strategy"] == "file_backed_task_memory_packet"
    assert budget["compression"]["summary_token_target"] == 1_200
    assert budget["governor"]["schema_version"] == "holtworks_context_budget_governor/v1"
    assert budget["governor"]["budget_state"] in ["soft_limit", "critical", "overflow"]

    assert Tasks.provider_profile("local-planner", %{})["provider"] == "local"
    assert Tasks.safety_policy(%{})["schema_version"] == "holtworks_safety_policy/v1"
    assert Tasks.runtime_context_budget(%{})["schema_version"] == "holtworks_context_budget/v1"
  end

  test "work graph orchestration derives schedule budget dispatch team and child contracts" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Orchestrated graph task",
                 "estimate" => 8,
                 "assignees" => [
                   %{"id" => "agent_one", "kind" => "agent", "work_role" => "worker"},
                   %{"id" => "agent_two", "kind" => "agent", "work_role" => "worker"},
                   %{"id" => "agent_three", "kind" => "agent", "work_role" => "worker"},
                   %{"id" => "agent_verify", "kind" => "agent", "work_role" => "verifier"}
                 ]
               },
               workspace: workspace
             )

    assert {:ok, graph} = Tasks.create_task_graph(task["ref"], %{}, workspace: workspace)

    assert {:ok, work_graph} =
             Tasks.work_graph(task["ref"], %{"graph_id" => graph["id"]}, workspace: workspace)

    assert work_graph["schema_version"] == "holtworks_work_graph/v1"
    assert work_graph["source"] == "task_graph"
    assert work_graph["task_graph_id"] == graph["id"]
    assert work_graph["completion_gate"]["status"] == "blocked"
    assert "required_node_incomplete" in work_graph_blocker_codes(work_graph)
    assert Enum.map(work_graph["nodes"], & &1["kind"]) == ~w(plan work verification integration)

    assert {:ok, schedule} =
             Tasks.work_graph_schedule(task["ref"], %{"graph_id" => graph["id"]},
               workspace: workspace
             )

    assert schedule["schema_version"] == "holtworks_work_graph_schedule/v1"
    assert schedule["status"] == "ready"
    assert [%{"node_key" => "plan", "schedule_status" => "ready"}] = schedule["ready_nodes"]

    assert schedule["next_actions"] == [
             "dispatch_ready_nodes",
             "wait_for_dependencies_or_external_input"
           ]

    assert {:ok, budget} =
             Tasks.work_graph_budget(
               task["ref"],
               %{"group_token_budget" => 80_000, "max_concurrent_agents" => 2},
               workspace: workspace
             )

    assert budget["schema_version"] == "holtworks_work_graph_budget/v1"
    assert budget["max_total_tokens"] == 80_000
    assert budget["max_concurrent_agents"] == 2
    assert budget["allocation"]["verification_reserve_tokens"] == 16_000

    assert {:ok, dispatch} =
             Tasks.agent_dispatch_plan(
               task["ref"],
               %{"max_agents_per_event" => 2, "group_token_budget" => 80_000},
               workspace: workspace
             )

    assert dispatch["schema_version"] == "holtworks_agent_dispatch/v1"
    assert dispatch["selected_agent_ids"] == ["agent_one", "agent_two"]
    assert dispatch["selected_count"] == 2
    assert dispatch["suppressed_count"] == 2
    assert dispatch["group_budget"]["max_total_tokens"] == 80_000
    assert get_in(dispatch, ["role_isolation", "verifier_context", "can_mutate"]) == false
    assert Enum.map(dispatch["verifier_shards"], & &1["shard_id"]) == ~w(evidence policy outcome)

    assert {:ok, team} = Tasks.team_orchestration(task["ref"], %{}, workspace: workspace)
    assert team["schema_version"] == "holtworks_team_orchestration/v1"
    assert team["mode"] == "planner_executor_verifier_team"
    assert team["max_concurrent_agents"] == 4

    assert {:ok, child} =
             Tasks.child_agent_contract(
               task["ref"],
               %{
                 "tool_name" => "start_agent_work",
                 "arguments" => %{
                   "target_agent_id" => "agent_one",
                   "work_role" => "worker",
                   "allowed_tools" => ["get_task"]
                 }
               },
               workspace: workspace
             )

    assert child["schema_version"] == "holtworks_child_agent_contract/v1"
    assert child["child"]["target_agent_id"] == "agent_one"
    assert child["authority_boundary"]["may_delegate_further"] == false
    assert child["verification_contract"]["verifier_required"] == true
  end

  test "stdio orchestration aliases accept Inktrail-style task identifiers" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)
    opts = [workspace: workspace]

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Stdio orchestration task",
                 "assignees" => [%{"id" => "agent_one", "kind" => "agent"}]
               },
               workspace: workspace
             )

    assert {:ok, _graph} = Tasks.create_task_graph(task["ref"], %{}, workspace: workspace)

    assert %{"ok" => true, "result" => work_graph} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "work_graph",
                 "params" => %{"task_id" => task["ref"]}
               },
               opts
             )

    assert work_graph["schema_version"] == "holtworks_work_graph/v1"

    assert %{"ok" => true, "result" => dispatch} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "agent_dispatch_plan",
                 "params" => %{"task_id" => task["ref"], "max_agents_per_event" => 1}
               },
               opts
             )

    assert dispatch["schema_version"] == "holtworks_agent_dispatch/v1"
    assert dispatch["selected_agent_ids"] == ["agent_one"]

    assert %{"ok" => true, "result" => schedule} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "schedule_work_graph",
                 "params" => %{"task_id" => task["ref"]}
               },
               opts
             )

    assert schedule["schema_version"] == "holtworks_work_graph_schedule/v1"
  end

  test "stdio runtime aliases expose Inktrail-style runtime contracts" do
    assert %{"ok" => true, "result" => provider} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "provider_profile",
                 "params" => %{"model" => "gpt-5.2"}
               },
               []
             )

    assert provider["schema_version"] == "holtworks_provider_profile/v1"
    assert provider["provider"] == "openai"

    assert %{"ok" => true, "result" => safety} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "safety_policy",
                 "params" => %{"task_complexity" => "implementation"}
               },
               []
             )

    assert safety["schema_version"] == "holtworks_safety_policy/v1"

    assert %{"ok" => true, "result" => tools} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tool_availability",
                 "params" => %{"tool_names" => ["get_task"]}
               },
               []
             )

    assert [%{"schema_version" => "holtworks_tool_availability/v1", "available" => true}] =
             tools

    assert %{"ok" => true, "result" => budget} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "runtime_context_budget",
                 "params" => %{
                   "provider_profile" => provider,
                   "estimated_input_tokens" => 4_000
                 }
               },
               []
             )

    assert budget["schema_version"] == "holtworks_context_budget/v1"

    assert %{"ok" => true, "result" => doctor} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "runtime_doctor",
                 "params" => %{"tool_names" => ["get_task"]}
               },
               []
             )

    assert doctor["schema_version"] == "holtworks_agent_runtime_doctor/v1"
    assert doctor["status"] == "ready"

    assert %{"ok" => true, "result" => recovery} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "recovery_contract",
                 "params" => %{
                   "tool_name" => "update_task",
                   "effect_scope" => "task_durable"
                 }
               },
               []
             )

    assert recovery["schema_version"] == "holtworks_recovery_contract/v1"
    assert recovery["rollback_plan"]["strategy"] == "compensating_task_update"

    assert %{"ok" => true, "result" => debugger} =
             Bridge.Stdio.handle_request(
               %{"method" => "run_debugger", "params" => %{"events" => []}},
               []
             )

    assert debugger["schema_version"] == "holtworks_run_debugger/v1"

    assert %{"ok" => true, "result" => learning} =
             Bridge.Stdio.handle_request(
               %{"method" => "meta_learning_snapshot", "params" => %{}},
               []
             )

    assert learning["schema_version"] == "holtworks_meta_learning_snapshot/v1"

    assert %{"ok" => true, "result" => %{"content" => sanitized}} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "format_local_model_result",
                 "params" => %{"content" => ~s({"command":"run","error":"boom"})}
               },
               []
             )

    assert sanitized == "Local model failed: boom"
  end

  test "agent runtime facade builds recovery debug sanitizer and meta-learning contracts" do
    recovery =
      AgentRuntime.recovery_contract(%{
        "tool_name" => "update_task",
        "effect_scope" => "task_durable",
        "risk_level" => "medium",
        "target_refs" => %{"task_ref" => "HW-01"}
      })

    assert recovery["schema_version"] == "holtworks_recovery_contract/v1"
    assert recovery["rollback_plan"]["strategy"] == "compensating_task_update"
    assert recovery["requires_recovery_observation"] == true
    assert recovery["requires_rollback_verification"] == true

    envelope = %{
      "envelope_id" => "env1",
      "tool_name" => "update_task",
      "tool_call_id" => "call1",
      "runtime_status" => "completed_repair_required",
      "execution_decision" => "execute",
      "approval_request" => %{"status" => "pending"},
      "repair_orchestration" => %{
        "repair_required" => true,
        "status" => "repair_required",
        "mode" => "repair_observed_error"
      },
      "prediction_error" => %{"matched" => false, "severity" => "medium"}
    }

    debugger =
      AgentRuntime.run_debugger(%{
        "run" => %{"id" => "run1", "agent_run_id" => "agent-run1"},
        "events" => [
          %{
            "type" => "action.completed",
            "at" => "2026-05-17T00:00:00Z",
            "metadata" => %{"action_runtime_envelope" => envelope}
          }
        ]
      })

    assert debugger["schema_version"] == "holtworks_run_debugger/v1"
    assert debugger["event_count"] == 1
    assert debugger["action_envelope_count"] == 1
    assert debugger["approval_wait_count"] == 1
    assert debugger["repair_required_count"] == 1
    assert debugger["prediction_mismatch_count"] == 1
    assert "resolve_human_approval" in debugger["next_debug_actions"]
    assert "inspect_repair_orchestration" in debugger["next_debug_actions"]
    assert "inspect_prediction_error" in debugger["next_debug_actions"]

    assert AgentRuntime.format_local_model_result(%{"command" => "run", "error" => "boom"}) ==
             "Local model failed: boom"

    assert AgentRuntime.format_local_model_result(%{"content" => "Ready"}) == "Ready"

    assert {:ok, "awaiting_verification"} =
             AgentRuntime.agent_run_lifecycle_transition("running", "awaiting_verification")

    assert {:error, {:invalid_agent_run_transition, "completed", "running"}} =
             AgentRuntime.agent_run_lifecycle_transition("completed", "running")

    assert AgentRuntime.agent_run_lifecycle_complete(%{
             "status" => "success",
             "verification_gate" => %{"status" => "required"}
           }) == "awaiting_verification"

    loop =
      AgentRuntime.agent_loop_contract(%{
        "task" => %{"id" => "task1", "ref" => "HW-01", "title" => "Loop task"},
        "agent" => %{"agent_id" => "agent_loop"},
        "continuation_count" => 1,
        "lifecycle_state" => "needs_continuation",
        "decision" => %{"action" => "continue", "depth" => 2}
      })

    assert loop["schema_version"] == "holtworks_agent_loop/v1"
    assert loop["status"] == "running"
    assert loop["continuation_depth"] == 1

    meta =
      AgentRuntime.meta_learning_snapshot(%{
        "outcome_calibrations" => [
          %{"calibration_id" => "cal1", "tool_name" => "update_task", "matched" => false}
        ],
        "repair_effectiveness" => [
          %{
            "repair_id" => "rep1",
            "source_tool_name" => "update_task",
            "effectiveness_status" => "pending_repair",
            "repair_required" => true
          }
        ],
        "verifier_quality" => [
          %{"verifier_agent_id" => "agent_verify", "accuracy" => 0.4, "sample_count" => 3}
        ],
        "prior_lessons" => [
          %{"task_pattern_key" => "pattern1", "application_mismatch_count" => 1}
        ]
      })

    assert meta["schema_version"] == "holtworks_meta_learning_snapshot/v1"
    assert meta["metrics"]["prediction_mismatch_count"] == 1
    assert meta["metrics"]["repair_required_count"] == 1

    reason_codes = Enum.map(meta["recommendations"], & &1["reason_code"])
    assert "repeated_prediction_mismatch" in reason_codes
    assert "repair_not_resolved" in reason_codes
    assert "low_verifier_accuracy" in reason_codes
    assert "lesson_application_mismatch" in reason_codes
    assert length(meta["proposed_policy_updates"]) == 4
  end

  test "task tool sessions scope direct tools and route action contracts" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} = Tasks.create(%{"title" => "Tool session task"}, workspace: workspace)

    assert {:ok, session} =
             Tasks.task_tool_session(
               task["ref"],
               %{
                 "agent_id" => "agent_tools",
                 "disabled_tools" => ["write_file"],
                 "connected_accounts" => %{
                   "github" => %{"connected_account_id" => "acct_github"}
                 }
               },
               workspace: workspace
             )

    assert session["schema_version"] == "holtworks_task_tool_session/v1"
    assert session["task_ref"] == task["ref"]
    assert "get_task" in session["direct_tools"]
    assert "read_file" in session["direct_tools"]
    refute "write_file" in session["direct_tools"]
    assert Enum.any?(session["meta_tools"], &(&1["name"] == "search_tools"))
    assert Enum.any?(session["meta_tools"], &(&1["name"] == "manage_connection"))
    assert Enum.any?(session["meta_tools"], &(&1["name"] == "use_workbench"))
    assert session["connected_accounts"]["github"]["connected_account_id"] == "acct_github"
    assert session["workbench"]["enabled"] == true

    assert {:ok, read_route} =
             Tasks.route_task_tool(
               task["ref"],
               %{"tool_name" => "get_task", "task_tool_session" => session},
               workspace: workspace
             )

    assert read_route["status"] == "accepted"
    assert read_route["route_kind"] == "direct"
    assert read_route["requires_approval"] == false
    assert read_route["action_contract"]["effect_scope"] == "read_only"

    assert {:ok, disabled_route} =
             Tasks.route_task_tool(
               task["ref"],
               %{"tool_name" => "write_file", "task_tool_session" => session},
               workspace: workspace
             )

    assert disabled_route["status"] == "rejected"
    assert disabled_route["reason"] == "tool_disabled_for_session"

    assert {:ok, command_route} =
             Tasks.route_task_tool(task["ref"], %{"tool_name" => "run_command"},
               workspace: workspace
             )

    assert command_route["status"] == "accepted"
    assert command_route["requires_approval"] == true
    assert command_route["action_contract"]["effect_scope"] == "workspace_durable"
  end

  test "task plan contracts gate tool actions before preflight" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} = Tasks.create(%{"title" => "Plan gated tools"}, workspace: workspace)

    assert {:ok, plan} = Tasks.plan_contract(task["ref"], %{}, workspace: workspace)
    assert plan["schema_version"] == "holtworks_plan_contract/v1"
    assert "get_task" in plan["allowed_tools"]
    refute "run_command" in plan["allowed_tools"]
    refute "workspace_durable" in plan["allowed_effect_scopes"]

    assert {:ok, read_gate} =
             Tasks.plan_gate(task["ref"], %{"tool_name" => "get_task"}, workspace: workspace)

    assert read_gate["schema_version"] == "holtworks_plan_gate/v1"
    assert read_gate["action"] == "approved"
    assert read_gate["reason"] == "active_plan_allows_action"

    assert {:ok, blocked_gate} =
             Tasks.plan_gate(task["ref"], %{"tool_name" => "run_command"}, workspace: workspace)

    assert blocked_gate["action"] == "rejected"
    assert blocked_gate["reason"] == "tool_not_in_active_plan"

    assert {:ok, read_preflight} =
             Tasks.action_preflight(task["ref"], %{"tool_name" => "get_task"},
               workspace: workspace
             )

    assert read_preflight["schema_version"] == "holtworks_action_preflight/v1"
    assert read_preflight["result"] == "passed"
    assert read_preflight["blocked_checks"] == []

    assert {:ok, blocked_preflight} =
             Tasks.action_preflight(task["ref"], %{"tool_name" => "run_command"},
               workspace: workspace
             )

    assert blocked_preflight["result"] == "blocked"
    assert "active_plan_allows_action" in blocked_preflight["blocked_checks"]

    assert {:ok, approved_workspace_plan} =
             Tasks.plan_contract(
               task["ref"],
               %{"allow_workspace_durable" => true},
               workspace: workspace
             )

    assert "run_command" in approved_workspace_plan["allowed_tools"]

    assert {:ok, approval_preflight} =
             Tasks.action_preflight(
               task["ref"],
               %{"tool_name" => "run_command", "allow_workspace_durable" => true},
               workspace: workspace
             )

    assert approval_preflight["result"] == "approval_required"
    assert approval_preflight["approval_required_checks"] == ["approval_granted"]
  end

  test "task action runtime envelope observes reconciles and repairs actions" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Runtime envelope for tool actions"},
               workspace: workspace
             )

    assert {:ok, gate} =
             Tasks.consequence_gate(task["ref"], %{"tool_name" => "get_task"},
               workspace: workspace
             )

    assert gate["schema_version"] == "holtworks_consequence_gate/v1"
    assert gate["action"] == "approved"
    assert gate["policy_decision"]["schema_version"] == "holtworks_policy_decision/v1"
    assert gate["prediction"]["schema_version"] == "holtworks_consequence_prediction/v1"
    assert gate["state_snapshot"]["schema_version"] == "holtworks_world_state_snapshot/v1"

    assert gate["state_transition_prediction"]["schema_version"] ==
             "holtworks_state_transition_prediction/v1"

    assert gate["state_invariant_check"]["status"] == "passed"
    assert gate["plan_gate"]["action_contract_id"] == gate["action_contract"]["contract_id"]
    assert gate["plan_gate"]["plan_id"] == gate["plan_contract"]["plan_id"]

    assert {:ok, envelope} =
             Tasks.action_runtime_envelope(task["ref"], %{"tool_name" => "get_task"},
               workspace: workspace
             )

    assert envelope["schema_version"] == "holtworks_action_runtime_envelope/v1"
    assert envelope["execution_decision"] == "execute"
    assert envelope["runtime_status"] == "ready_to_execute"
    assert "observe" in envelope["required_lifecycle"]

    assert envelope["plan_gate"]["action_contract_id"] ==
             envelope["action_contract"]["contract_id"]

    assert envelope["plan_gate"]["plan_id"] == envelope["plan_contract"]["plan_id"]

    assert {:ok, completed} =
             Tasks.complete_action_runtime_envelope(envelope, %{
               "result" => %{"status" => "ok", "preview" => "task read"},
               "latency_ms" => 3
             })

    assert completed["runtime_status"] == "completed_continue"

    assert completed["execution_observation"]["schema_version"] ==
             "holtworks_execution_observation/v1"

    assert completed["prediction_error"]["schema_version"] == "holtworks_prediction_error/v1"
    assert completed["prediction_error"]["matched"] == true

    assert completed["state_reconciliation"]["schema_version"] ==
             "holtworks_state_reconciliation/v1"

    assert completed["state_reconciliation"]["matched"] == true

    assert completed["outcome_calibration"]["schema_version"] ==
             "holtworks_outcome_calibration/v1"

    assert completed["outcome_calibration"]["matched"] == true
    assert completed["repair_orchestration"]["status"] == "not_required"

    assert {:ok, failed} =
             Tasks.complete_action_runtime_envelope(envelope, %{
               "result" => %{"status" => "error", "preview" => "validation failed"},
               "latency_ms" => 4
             })

    assert failed["runtime_status"] == "completed_repair_required"
    assert failed["prediction_error"]["matched"] == false
    assert failed["state_reconciliation"]["matched"] == false
    assert failed["repair_orchestration"]["status"] == "repair_required"
  end

  test "task action approvals and evidence ledgers are durable audit records" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Audit action runtime outcomes"}, workspace: workspace)

    assert {:ok, request} =
             Tasks.action_approval_request(
               task["ref"],
               %{"tool_name" => "run_command", "allow_workspace_durable" => true},
               workspace: workspace
             )

    assert request["schema_version"] == "holtworks_human_approval_request/v1"
    assert request["status"] == "pending"
    assert request["effect_scope"] == "workspace_durable"
    assert request["reason"] == "action_preflight_requires_approval"

    approval_path = Path.join([workspace, ".holtworks", "tasks", "human_approval_requests.json"])
    assert [stored_request] = JSON.read(approval_path, [])
    assert stored_request["approval_request_id"] == request["approval_request_id"]

    assert {:ok, resolved} =
             Tasks.resolve_action_approval_request(
               request["approval_request_id"],
               %{"decision" => "approved", "decided_by" => "tester"},
               workspace: workspace
             )

    assert resolved["status"] == "approved"
    assert resolved["resolution"]["schema_version"] == "holtworks_human_approval_resolution/v1"
    assert resolved["resolution"]["can_resume"] == true

    assert {:ok, ledger} =
             Tasks.action_evidence_ledger(
               task["ref"],
               %{
                 "tool_name" => "get_task",
                 "result_status" => "ok",
                 "result_preview" => "task read",
                 "artifact_ref" => "artifact://tool/get_task"
               },
               workspace: workspace
             )

    assert ledger["schema_version"] == "holtworks_evidence_ledger/v1"
    assert ledger["task_ref"] == task["ref"]
    assert ledger["coverage"]["has_prediction"] == true
    assert ledger["coverage"]["has_observation"] == true
    assert ledger["coverage"]["has_calibration"] == true
    assert ledger["coverage"]["has_repair"] == true
    assert "action_contract" in ledger["coverage"]["entry_kinds"]
    assert "execution_observation" in ledger["coverage"]["entry_kinds"]
    assert "outcome_calibration" in ledger["coverage"]["entry_kinds"]

    ledger_path = Path.join([workspace, ".holtworks", "tasks", "evidence_ledgers.json"])
    assert [stored_ledger] = JSON.read(ledger_path, [])
    assert stored_ledger["ledger_id"] == ledger["ledger_id"]
  end

  test "task memory context budgets and continuation packets preserve exact evidence" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)
    opts = [home: home, workspace: workspace, approval: :always_approve]

    assert {:ok, task} =
             Tasks.create(%{"title" => "Long-running memory task"}, workspace: workspace)

    assert {:ok, _spec} =
             Tasks.save_spec(
               task["ref"],
               %{
                 "kind" => "handoff",
                 "title" => "Prior handoff",
                 "content" => "Use the file-backed packet as source of truth."
               },
               workspace: workspace
             )

    assert {:ok, artifact} =
             Tasks.record_task_memory_artifact(
               task["ref"],
               %{
                 "kind" => "handoff",
                 "title" => "Exact evidence",
                 "content" => String.duplicate("exact evidence line\n", 200)
               },
               workspace: workspace
             )

    assert artifact["schema_version"] == "holtworks_task_memory_artifact/v1"
    assert artifact["chunk_count"] >= 1

    assert {:ok, read_artifact} =
             Tasks.read_memory_artifact(artifact["artifact_ref"], workspace: workspace)

    assert read_artifact["content"] =~ "exact evidence line"

    assert {:ok, packet} =
             Tasks.task_memory_context(
               task["ref"],
               %{"estimated_input_tokens" => 100_000},
               workspace: workspace
             )

    assert packet["schema_version"] == "holtworks_task_memory_context_packet/v1"
    assert packet["memory_state"]["runtime_spec_count"] == 1
    assert packet["memory_state"]["artifact_count"] == 1
    assert packet["context_budget"]["budget_state"] == "soft_limit"
    assert packet["context_budget"]["action"] == "snapshot_soon"
    assert artifact["artifact_ref"] in packet["artifact_refs"]

    packet_path = HoltWorks.Tasks.TaskMemory.context_packets_path(workspace)
    assert [stored_packet] = JSON.read(packet_path, [])
    assert stored_packet["packet_id"] == packet["packet_id"]

    assert {:ok, first_run} =
             Tasks.start_agent_work(task["ref"], %{"message" => "First pass."}, opts)

    assert {:ok, continuation_packet} =
             Tasks.continuation_packet(task["ref"], %{}, opts)

    assert continuation_packet["schema_version"] == "holtworks_continuation_packet/v1"
    assert continuation_packet["previous_runtime_run_id"] == first_run[:run]["id"]
    assert continuation_packet["context_packet_id"]
    assert continuation_packet["required_loop"]["load_task_memory_context"] == true

    assert {:ok, continued} =
             Tasks.continue_agent_work(task["ref"], %{"message" => "Continue with packet."}, opts)

    assert continued[:agent_work]["kind"] == "continuation"

    assert continued[:agent_work]["continuation_packet"]["schema_version"] ==
             "holtworks_continuation_packet/v1"

    assert continued[:agent_work]["context_packet_id"]
  end

  test "task capability contracts route assigned agents and build generic plans" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Capability routed work",
                 "assignees" => [
                   %{
                     "id" => "agent-a",
                     "display_name" => "Agent A",
                     "work_role" => "worker"
                   }
                 ]
               },
               workspace: workspace
             )

    assert {:ok, entry} = Tasks.capability_registry("get_task", %{})
    assert entry["schema_version"] == "holtworks_capability_registry_entry/v1"
    assert entry["tool_name"] == "get_task"
    assert entry["effect_scope"] == "read_only"
    assert entry["registered"] == true

    assert {:ok, contract} =
             Tasks.capability_contract(task["ref"], %{"tool_name" => "get_task"},
               workspace: workspace
             )

    assert contract["schema_version"] == "holtworks_capability_contract/v1"
    assert contract["required_tools"] == ["get_task"]
    assert "tool:get_task" in contract["required_capabilities"]
    assert "effect_scope:read_only" in contract["required_capabilities"]

    assert {:ok, route} =
             Tasks.capability_route(task["ref"], %{"tool_name" => "get_task"},
               workspace: workspace
             )

    assert route["schema_version"] == "holtworks_capability_route/v1"
    assert route["status"] == "routed"
    assert route["execution_mode"] == "persisted_agent"
    assert route["target_agent_id"] == "agent-a"

    assert {:ok, plan} = Tasks.generic_plan(task["ref"], %{}, workspace: workspace)
    assert plan["schema_version"] == "holtworks_generic_work_graph/v1"
    assert plan["node_types"] == ~w(research propose act verify repair)
    assert Enum.map(plan["nodes"], & &1["phase"]) == ~w(research propose act verify repair)
    assert graph_node(plan, "research")["status"] == "scheduled"
    assert "get_task" in graph_node(plan, "research")["allowed_tools"]
    assert "route_verification_review" in graph_node(plan, "verify")["allowed_tools"]
  end

  test "task continuation resumes from latest task run and appends agent work" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Continue workspace task"}, workspace: workspace)

    assert {:ok, %{task: after_first, run: first_run, agent_work: first_work}} =
             Tasks.start_agent_work(
               task["ref"],
               %{"message" => "Create first pass."},
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert length(after_first["agent_work"]) == 1
    assert first_work["iteration"] == 1

    assert {:ok, %{task: after_continue, run: second_run, agent_work: second_work}} =
             Tasks.continue_agent_work(
               task["ref"],
               %{"message" => "Continue from the first pass."},
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert second_run["status"] == "completed"
    assert second_run["resumed_from"] == first_run["id"]
    assert second_work["kind"] == "continuation"
    assert second_work["iteration"] == 2
    assert second_work["continuation_of"] == first_work["id"]
    assert second_work["resumed_from_run_id"] == first_run["id"]
    assert length(after_continue["agent_work"]) == 2
    assert after_continue["status"] == "waiting"

    assert [first_agent_run, second_agent_run] = Tasks.agent_runs(workspace: workspace)
    assert first_agent_run["source"] == "task_agent_request"
    assert second_agent_run["source"] == "task_agent_continuation"
    assert second_agent_run["previous_run_id"] == first_run["id"]
  end

  test "agent profiles cards and lifecycle feed task dispatch" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, alpha} =
             Tasks.create_agent(
               %{
                 "id" => "agent_alpha",
                 "display_name" => "Alpha Builder",
                 "agent_handle" => "alpha",
                 "work_roles" => ["worker", "verifier"],
                 "skills" => [
                   %{"name" => "Planning", "tool_names" => ["plan_contract"]},
                   "Implementation"
                 ],
                 "model" => "local-planner"
               },
               workspace: workspace
             )

    assert alpha["schema_version"] == "holtworks_agent_profile/v1"
    assert alpha["agent_handle"] == "@alpha"
    assert Enum.map(alpha["skills"], & &1["id"]) == ["planning", "implementation"]

    assert {:ok, beta} =
             Tasks.create_agent(
               %{"id" => "agent_beta", "display_name" => "Beta Reviewer"},
               workspace: workspace
             )

    assert {:ok, suspended_beta} =
             Tasks.suspend_agent(beta["id"], %{"reason" => "maintenance"}, workspace: workspace)

    assert suspended_beta["status"] == "suspended"

    assert {:ok, card} = Tasks.agent_card("agent_alpha", workspace: workspace)
    assert card["schema_version"] == "holtworks_agent_card/v1"
    assert card["skills"] |> Enum.map(& &1["name"]) == ["Planning", "Implementation"]

    assert {:ok, skills} = Tasks.agent_skills("agent_alpha", workspace: workspace)
    assert Enum.map(skills, & &1["name"]) == ["Planning", "Implementation"]

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Profile-backed dispatch",
                 "assignees" => ["agent_alpha", "agent_beta"]
               },
               workspace: workspace
             )

    assert {:ok, fetched} = Tasks.get(task["ref"], workspace: workspace)
    assert [enriched_alpha, enriched_beta] = fetched["assignees"]
    assert enriched_alpha["display_name"] == "Alpha Builder"
    assert enriched_alpha["agent_card"]["schema_version"] == "holtworks_agent_card/v1"
    assert enriched_beta["status"] == "suspended"

    assert {:ok, result} =
             Tasks.start_agent_work(
               task["ref"],
               %{"message" => "Dispatch through active profile.", "max_agents_per_event" => 2},
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert Enum.map(result[:started], & &1["agent_id"]) == ["agent_alpha"]
    assert result[:dispatch_plan]["selected_agent_ids"] == ["agent_alpha"]

    assert get_in(result[:dispatch_plan], ["selected_agents", Access.at(0), "agent_card", "id"]) ==
             "agent_alpha"

    assert [agent_run] = Tasks.agent_runs(workspace: workspace)
    assert agent_run["agent_id"] == "agent_alpha"

    assert %{"ok" => true, "result" => stdio_agent} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "create_agent",
                 "params" => %{
                   "id" => "agent_gamma",
                   "display_name" => "Gamma Specialist",
                   "skills" => ["Research"]
                 }
               },
               workspace: workspace
             )

    assert stdio_agent["id"] == "agent_gamma"

    assert %{"ok" => true, "result" => stdio_card} =
             Bridge.Stdio.handle_request(
               %{"method" => "get_agent_card", "params" => %{"agent_id" => "agent_gamma"}},
               workspace: workspace
             )

    assert stdio_card["display_name"] == "Gamma Specialist"

    cli_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "agents",
                 "list",
                 "--workspace",
                 workspace
               ]) == 0
      end)

    assert cli_output =~ "Alpha Builder"
    assert cli_output =~ "Gamma Specialist"
  end

  test "agent profile tools are exposed through the action catalog" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)
    action_opts = [workspace: workspace, approval: :always_approve]

    assert {:ok, create_execution} =
             Tasks.execute_action(
               "create_agent",
               %{
                 "id" => "agent_delta",
                 "display_name" => "Delta Planner",
                 "agent_handle" => "delta",
                 "agent_ref" => "DELTA-1",
                 "work_roles" => ["planner", "verifier"],
                 "skills" => [%{"name" => "Planning", "tool_names" => ["plan_contract"]}],
                 "model" => "local-planner"
               },
               action_opts
             )

    assert create_execution["status"] == "ok"
    assert create_execution["result"]["id"] == "agent_delta"
    assert create_execution["result"]["agent_handle"] == "@delta"

    assert {:ok, list_execution} =
             Tasks.execute_action("list_agents", %{"status" => "active"}, workspace: workspace)

    assert Enum.any?(list_execution["result"]["agents"], &(&1["id"] == "agent_delta"))

    assert {:ok, card_execution} =
             Tasks.execute_action("get_agent_card", %{"handle" => "delta"}, workspace: workspace)

    assert card_execution["result"]["id"] == "agent_delta"
    assert card_execution["result"]["work_roles"] == ["planner", "verifier"]

    assert {:ok, skill_execution} =
             Tasks.execute_action("list_agent_skills", %{"agent_ref" => "DELTA-1"},
               workspace: workspace
             )

    assert [%{"name" => "Planning"}] = skill_execution["result"]["skills"]

    assert {:ok, update_execution} =
             Tasks.execute_action(
               "update_agent",
               %{
                 "agent_id" => "agent_delta",
                 "display_name" => "Delta Reviewer",
                 "skills" => ["Review"]
               },
               action_opts
             )

    assert update_execution["result"]["display_name"] == "Delta Reviewer"
    assert [%{"name" => "Review"}] = update_execution["result"]["skills"]

    assert {:ok, suspend_execution} =
             Tasks.execute_action(
               "suspend_agent",
               %{"agent_id" => "agent_delta", "reason" => "rotation"},
               action_opts
             )

    assert suspend_execution["result"]["status"] == "suspended"

    assert {:error, invoke_blocked} =
             Tasks.execute_action(
               "invoke_agent",
               %{
                 "agent_id" => "agent_delta",
                 "instructions" => "Plan the next implementation slice.",
                 "target_skill" => "planning",
                 "validation_contract" => "Return a bounded handoff."
               },
               action_opts
             )

    assert invoke_blocked["status"] == "error"
    assert invoke_blocked["reason"] == "agent_not_invokable"

    assert {:ok, resume_execution} =
             Tasks.execute_action("resume_agent", %{"agent_id" => "agent_delta"}, action_opts)

    assert resume_execution["result"]["status"] == "active"

    assert {:ok, invoke_execution} =
             Tasks.execute_action(
               "invoke_agent",
               %{
                 "agent_id" => "agent_delta",
                 "instructions" => "Plan the next implementation slice.",
                 "target_skill" => "planning",
                 "work_role" => "planner",
                 "validation_contract" => "Return a bounded handoff.",
                 "allowed_tools" => ["read_file", "search_files"]
               },
               action_opts
             )

    assert invoke_execution["result"]["schema_version"] == "holtworks_agent_invocation/v1"
    assert invoke_execution["result"]["agent_id"] == "agent_delta"

    assert get_in(invoke_execution, ["result", "child_agent_contract", "tool_name"]) ==
             "invoke_agent"

    catalog =
      Tasks.action_catalog(%{"action_provider_ids" => ["workspace"]}, workspace: workspace)

    names = Enum.map(catalog, & &1["name"])
    assert "list_agents" in names
    assert "create_agent" in names
    assert "invoke_agent" in names

    delete_entry = Enum.find(catalog, &(&1["name"] == "delete_agent"))
    assert delete_entry["requires_approval"] == true
    assert delete_entry["input_schema"]["required"] == ["agent_id", "confirm"]

    assert %{"ok" => true, "result" => stdio_invoke} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "invoke_agent",
                 "params" => %{
                   "agent_id" => "agent_delta",
                   "instructions" => "Prepare a review handoff.",
                   "target_skill" => "review",
                   "validation_contract" => "Return evidence and risks."
                 }
               },
               action_opts
             )

    assert get_in(stdio_invoke, ["result", "agent_card", "id"]) == "agent_delta"

    assert {:ok, delete_execution} =
             Tasks.execute_action(
               "delete_agent",
               %{"agent_id" => "agent_delta", "confirm" => true},
               action_opts
             )

    assert delete_execution["result"]["status"] == "deleted"

    assert {:ok, after_delete_execution} =
             Tasks.execute_action("list_agents", %{}, workspace: workspace)

    refute Enum.any?(after_delete_execution["result"]["agents"], &(&1["id"] == "agent_delta"))
  end

  test "core UI tools manage structured questions delegation pages and documents" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)
    action_opts = [workspace: workspace, approval: :always_approve]

    assert {:ok, question_execution} =
             Tasks.execute_action(
               "ask_user_question",
               %{
                 "question" => "Which path should continue?",
                 "description" => "Pick one.",
                 "options" => [%{"label" => "Plan", "value" => "plan"}]
               },
               action_opts
             )

    assert question_execution["result"]["schema_version"] == "holtworks_user_question/v1"
    assert question_execution["result"]["status"] == "await_user"
    assert question_execution["result"]["options"] == [%{"label" => "Plan", "value" => "plan"}]

    assert {:ok, delegation_execution} =
             Tasks.execute_action(
               "delegate_to_agent",
               %{
                 "role" => "researcher",
                 "work_role" => "researcher",
                 "system_prompt" => "Research with structured evidence only.",
                 "instructions" => "Find the relevant facts.",
                 "target_skill" => "research.web",
                 "validation_contract" => "Return sources and unresolved risks.",
                 "allowed_tools" => ["search_web"]
               },
               action_opts
             )

    delegation = delegation_execution["result"]
    assert delegation["schema_version"] == "holtworks_agent_delegation/v1"
    assert delegation["status"] == "ready"
    assert delegation["role"] == "researcher"
    assert get_in(delegation, ["child_agent_contract", "tool_name"]) == "delegate_to_agent"
    assert get_in(delegation, ["child_agent_contract", "child", "work_role"]) == "researcher"

    assert {:ok, create_execution} =
             Tasks.execute_action(
               "create_page",
               %{
                 "page_type" => "document",
                 "title" => "Spec Draft",
                 "content" => "Initial"
               },
               action_opts
             )

    page = create_execution["result"]["page"]
    assert page["schema_version"] == "holtworks_page/v1"
    assert page["title"] == "Spec Draft"

    assert {:ok, title_execution} =
             Tasks.execute_action(
               "set_page_title",
               %{"page_id" => page["id"], "title" => "Spec Draft v2"},
               action_opts
             )

    assert title_execution["result"]["page"]["title"] == "Spec Draft v2"

    assert {:ok, replace_execution} =
             Tasks.execute_action(
               "write_to_document",
               %{
                 "page_id" => page["id"],
                 "action" => "replace_all",
                 "content" => "# Spec\n\nBody"
               },
               action_opts
             )

    assert replace_execution["result"]["document_event"]["edit_status"] == "replaced_all"

    assert %{"ok" => true, "result" => stdio_execution} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "documents/write",
                 "params" => %{
                   "page_id" => page["id"],
                   "action" => "insert_below",
                   "content" => "More"
                 }
               },
               action_opts
             )

    assert stdio_execution["result"]["document_event"]["edit_status"] == "inserted_below"

    document_path = Path.join(workspace, page["document_path"])
    assert File.read!(document_path) == "# Spec\n\nBody\n\nMore"

    catalog =
      Tasks.action_catalog(%{"action_provider_ids" => ["workspace"]}, workspace: workspace)

    names = Enum.map(catalog, & &1["name"])
    assert "ask_user_question" in names
    assert "delegate_to_agent" in names
    assert "create_page" in names
    assert "write_to_document" in names

    create_entry = Enum.find(catalog, &(&1["name"] == "create_page"))
    assert create_entry["requires_approval"] == true
    assert create_entry["input_schema"]["required"] == ["page_type", "title"]

    write_entry = Enum.find(catalog, &(&1["name"] == "write_to_document"))
    assert write_entry["requires_approval"] == true
    assert write_entry["input_schema"]["required"] == ["action", "content"]
  end

  test "repair run tools manage a structured repair workflow" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)
    action_opts = [workspace: workspace, approval: :always_approve]

    assert {:ok, start_execution} =
             Tasks.execute_action(
               "start_repair_run",
               %{
                 "task_id" => "HW-42",
                 "agent_run_id" => "agent-run-1",
                 "risk_level" => "high",
                 "goal_contract" => %{
                   "original_issue" => "Checkout fails for a known structured case.",
                   "success_criteria" => ["original_issue_check_passed", "impact_check_passed"]
                 }
               },
               action_opts
             )

    run = start_execution["result"]["repair_run"]
    assert run["schema_version"] == "holtworks_repair_run/v1"
    assert run["approval_status"] == "required"

    repair_run_id = run["id"]

    assert {:ok, _prediction_execution} =
             Tasks.execute_action(
               "record_repair_run_artifact",
               %{
                 "repair_run_id" => repair_run_id,
                 "artifact_type" => "prediction",
                 "payload" => %{
                   "id" => "prediction-1",
                   "expected_result_status" => "passed",
                   "state_delta" => %{"checkout_flow" => "restored"}
                 }
               },
               action_opts
             )

    assert {:ok, _observation_execution} =
             Tasks.execute_action(
               "record_repair_run_artifact",
               %{
                 "repair_run_id" => repair_run_id,
                 "artifact_type" => "observation",
                 "payload" => %{
                   "id" => "observation-1",
                   "actual_result_status" => "passed",
                   "state_delta" => %{"checkout_flow" => "restored"}
                 }
               },
               action_opts
             )

    assert {:ok, reconcile_execution} =
             Tasks.execute_action(
               "reconcile_repair_prediction",
               %{
                 "repair_run_id" => repair_run_id,
                 "prediction_id" => "prediction-1",
                 "observation_id" => "observation-1",
                 "matched" => true,
                 "next_decision" => "finish"
               },
               action_opts
             )

    assert [reconciliation] = reconcile_execution["result"]["repair_run"]["reconciliations"]
    assert reconciliation["matched"] == true

    assert {:ok, score_execution} =
             Tasks.execute_action(
               "score_repair_predictions",
               %{"repair_run_id" => repair_run_id, "notes" => "Prediction matched observation."},
               action_opts
             )

    assert score_execution["result"]["prediction_score"]["recommendation"] == "finish"

    assert {:ok, strategy_execution} =
             Tasks.execute_action(
               "choose_repair_strategy",
               %{
                 "repair_run_id" => repair_run_id,
                 "strategy" => "multi_file_repair",
                 "risk_level" => "high"
               },
               action_opts
             )

    assert strategy_execution["result"]["repair_run"]["strategy"] == "multi_file_repair"

    assert {:error, blocked_begin_execution} =
             Tasks.execute_action(
               "begin_repair_implementation",
               %{"repair_run_id" => repair_run_id},
               action_opts
             )

    assert blocked_begin_execution["status"] == "error"
    assert blocked_begin_execution["reason"] == "repair_gate_approval_required"

    assert {:ok, blast_execution} =
             Tasks.execute_action(
               "draft_repair_blast_radius",
               %{
                 "repair_run_id" => repair_run_id,
                 "changed_files" => ["lib/checkout.ex"],
                 "protected_flows" => ["checkout"],
                 "affected_domains" => ["payments"],
                 "verification_matrix" => [
                   %{"flow" => "checkout", "required_status" => "passed"}
                 ]
               },
               action_opts
             )

    assert blast_execution["result"]["blast_radius_draft"]["schema_version"] ==
             "holtworks_repair_blast_radius/v1"

    assert {:ok, approve_execution} =
             Tasks.execute_action(
               "approve_repair_gate",
               %{"repair_run_id" => repair_run_id, "reason_code" => "test_high_risk_repair"},
               action_opts
             )

    assert approve_execution["result"]["repair_run"]["approval_status"] == "approved"

    assert {:ok, begin_execution} =
             Tasks.execute_action(
               "begin_repair_implementation",
               %{"repair_run_id" => repair_run_id},
               action_opts
             )

    assert begin_execution["result"]["repair_run"]["phase"] == "implementation"

    assert {:ok, original_check_execution} =
             Tasks.execute_action(
               "execute_repair_original_issue_check",
               %{
                 "repair_run_id" => repair_run_id,
                 "goal_check" => %{
                   "original_issue_fixed" => true,
                   "evidence_refs" => ["check:checkout"]
                 },
                 "manual_check_results" => [
                   %{"check_key" => "check:checkout", "status" => "passed"}
                 ]
               },
               action_opts
             )

    assert original_check_execution["result"]["original_issue_check_execution"]["status"] ==
             "passed"

    assert {:ok, impact_execution} =
             Tasks.execute_action(
               "execute_repair_impact_check",
               %{
                 "repair_run_id" => repair_run_id,
                 "protected_flow_results" => [
                   %{
                     "flow" => "checkout",
                     "status" => "passed",
                     "evidence_refs" => ["check:checkout"]
                   }
                 ],
                 "affected_domain_results" => [
                   %{"domain" => "payments", "status" => "passed"}
                 ]
               },
               action_opts
             )

    assert impact_execution["result"]["impact_check_execution"]["status"] == "passed"

    assert {:ok, related_execution} =
             Tasks.execute_action(
               "draft_repair_related_issue_sweep",
               %{
                 "repair_run_id" => repair_run_id,
                 "candidate_related_issues" => [],
                 "should_fix_now" => false
               },
               action_opts
             )

    assert related_execution["result"]["related_issue_sweep_draft"]["status"] == "passed"

    assert {:ok, complete_execution} =
             Tasks.execute_action(
               "complete_repair_run",
               %{
                 "repair_run_id" => repair_run_id,
                 "final_report" => %{
                   "root_cause" => "structured_test_case",
                   "verification" => %{
                     "original_issue_check" => "passed",
                     "impact_check" => "passed"
                   }
                 }
               },
               action_opts
             )

    assert complete_execution["result"]["repair_run"]["status"] == "completed"
    assert complete_execution["result"]["repair_run"]["phase"] == "complete"

    assert %{"ok" => true, "result" => get_result} =
             Bridge.Stdio.handle_request(
               %{"method" => "get_repair_run", "params" => %{"repair_run_id" => repair_run_id}},
               workspace: workspace
             )

    assert get_result["result"]["repair_run"]["id"] == repair_run_id

    catalog =
      Tasks.action_catalog(%{"action_provider_ids" => ["workspace"]}, workspace: workspace)

    names = Enum.map(catalog, & &1["name"])
    assert "start_repair_run" in names
    assert "complete_repair_run" in names

    complete_entry = Enum.find(catalog, &(&1["name"] == "complete_repair_run"))
    assert complete_entry["requires_approval"] == true
    assert complete_entry["input_schema"]["required"] == ["repair_run_id"]
  end

  test "assigned agent dispatch starts selected idle agents and records suppression" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Dispatch assigned agents",
                 "assignees" => [
                   %{"id" => "person_1", "kind" => "person", "display_name" => "Human Owner"},
                   %{
                     "id" => "agent_alpha",
                     "kind" => "agent",
                     "display_name" => "Alpha",
                     "agent_handle" => "@alpha"
                   },
                   %{
                     "id" => "agent_beta",
                     "kind" => "agent",
                     "display_name" => "Beta",
                     "agent_ref" => "B-02"
                   },
                   %{"id" => "agent_gamma", "kind" => "agent", "display_name" => "Gamma"}
                 ]
               },
               workspace: workspace
             )

    assert {:ok, result} =
             Tasks.start_agent_work(
               task["ref"],
               %{
                 "message" => "Run assigned dispatch.",
                 "max_agents_per_event" => 2
               },
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert Enum.map(result[:started], & &1["agent_id"]) == ["agent_alpha", "agent_beta"]
    assert result[:dispatch_plan]["selected_count"] == 2
    assert result[:dispatch_plan]["suppressed_count"] == 1

    assert [%{"agent_id" => "agent_gamma", "reason" => "dispatch_cap_reached"}] =
             result[:dispatch_plan]["suppressed_agents"]

    assert {:ok, final_task} = Tasks.get(task["ref"], workspace: workspace)
    assert Enum.map(final_task["agent_work"], & &1["agent_id"]) == ["agent_alpha", "agent_beta"]

    agent_runs = Tasks.agent_runs(workspace: workspace)
    assert length(agent_runs) == 2
    assert Enum.map(agent_runs, & &1["agent_id"]) == ["agent_alpha", "agent_beta"]
    assert Enum.all?(agent_runs, &(&1["dispatch_id"] == result[:dispatch_plan]["dispatch_id"]))
    assert Enum.all?(agent_runs, &(&1["dispatch_plan"]["selected_count"] == 2))
  end

  test "stdio start_agent_work supports Inktrail-style task batch requests" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)
    opts = [home: home, workspace: workspace, approval: :always_approve]

    assert {:ok, first} =
             Tasks.create(
               %{
                 "title" => "Batch first",
                 "assignees" => [%{"id" => "agent_one", "kind" => "agent"}]
               },
               workspace: workspace
             )

    assert {:ok, second} =
             Tasks.create(
               %{
                 "title" => "Batch second",
                 "assignees" => [%{"id" => "agent_two", "kind" => "agent"}]
               },
               workspace: workspace
             )

    assert %{"ok" => true, "result" => batch_result} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "start_agent_work",
                 "params" => %{
                   "task_ids" => [first["ref"], second["ref"]],
                   "message" => "Run the batch."
                 }
               },
               opts
             )

    assert batch_result[:started_count] == 2
    assert Enum.map(batch_result[:results], & &1[:task]["ref"]) == [first["ref"], second["ref"]]

    assert Tasks.agent_runs(workspace: workspace)
           |> Enum.map(& &1["task_ref"]) == [first["ref"], second["ref"]]
  end

  test "automatic continuation follows structured depth policy and records suppression" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Auto continuation task", "estimate" => 8},
               workspace: workspace
             )

    assert {:ok, result} =
             Tasks.start_agent_work(
               task["ref"],
               %{
                 "message" => "Run with automatic continuation.",
                 "auto_continue" => true,
                 "max_continuation_depth" => 2
               },
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert result[:continuation_decision]["action"] == "continue"
    assert result[:auto_continuation]
    assert length(result[:task]["agent_work"]) == 3

    activity_types = Enum.map(result[:task]["activity"], & &1["type"])
    assert Enum.count(activity_types, &(&1 == "agent_continuation_requested")) == 2
    assert "agent_continuation_suppressed" in activity_types

    agent_runs = Tasks.agent_runs(workspace: workspace)
    assert length(agent_runs) == 3

    assert Enum.map(agent_runs, & &1["continuation_decision"]["action"]) == [
             "continue",
             "continue",
             "suppress"
           ]

    assert Enum.at(agent_runs, 1)["source"] == "task_agent_continuation"

    assert Enum.at(agent_runs, 2)["continuation_decision"]["reason"] ==
             "max_continuation_depth_reached"

    Tasks.agent_run_events(workspace: workspace)
    |> Enum.map(& &1["type"])
    |> assert_event_types(["agent_run.continuation_decision"])
  end

  test "blocked task run is classified and automatic continuation is suppressed" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Blocked automatic continuation task"},
               workspace: workspace
             )

    assert {:ok, result} =
             Tasks.start_agent_work(
               task["ref"],
               %{
                 "message" => "Approval should block this run.",
                 "auto_continue" => true,
                 "max_continuation_depth" => 2
               },
               home: home,
               workspace: workspace,
               approval: :always_deny
             )

    assert result[:run]["status"] == "blocked"
    assert result[:agent_work]["status"] == "blocked"
    assert result[:continuation_decision]["action"] == "suppress"
    assert result[:continuation_decision]["blocker_code"] == "approval_denied"
    refute Map.has_key?(result, :auto_continuation)

    assert [agent_run] = Tasks.agent_runs(workspace: workspace)
    assert agent_run["failure_class"] == "approval_denied"
    assert agent_run["blocker_code"] == "approval_denied"
    assert agent_run["failure_retryable"] == false
  end

  test "watchdog recovers stale agent runs with a structured recovery packet" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(
               %{
                 "title" => "Watchdog recovery task",
                 "assignees" => [%{"id" => "agent_watch", "kind" => "agent"}]
               },
               workspace: workspace
             )

    assert {:ok, %{agent_work: work}} =
             Tasks.start_agent_work(
               task["ref"],
               %{"message" => "Initial watchdog run."},
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert [agent_run] = Tasks.agent_runs(workspace: workspace)
    mark_agent_run_stale(workspace, task["id"], work["id"], agent_run["id"])

    assert [
             %{
               "action" => "recovery_queued",
               "reason" => "stale_run",
               "agent_id" => "agent_watch"
             }
           ] =
             Tasks.watchdog_scan(
               home: home,
               workspace: workspace,
               approval: :always_approve,
               stale_after_seconds: 1,
               recovery_cooldown_seconds: 60
             )

    assert {:ok, recovered_task} = Tasks.get(task["ref"], workspace: workspace)
    assert [old_work, recovery_work] = recovered_task["agent_work"]
    assert old_work["status"] == "recovery_queued"

    assert old_work["watchdog_recovery_packet"]["schema_version"] ==
             "holtworks_agent_run_watchdog_recovery/v1"

    assert old_work["watchdog_recovery_packet"]["previous_agent_run_id"] == agent_run["id"]
    assert recovery_work["kind"] == "continuation"
    assert recovery_work["source"] == "task_agent_watchdog_recovery"
    assert recovery_work["resumed_from_run_id"] == work["run_id"]

    [recovered_old_run, recovery_run] = Tasks.agent_runs(workspace: workspace)
    assert recovered_old_run["watchdog_status"] == "recovery_queued"
    assert recovered_old_run["watchdog_recovery_packet"]["reason"] == "stale_run"
    assert recovery_run["source"] == "task_agent_watchdog_recovery"
    assert recovery_run["previous_run_id"] == work["run_id"]

    recovered_task["activity"]
    |> Enum.map(& &1["type"])
    |> assert_event_types(["agent_watchdog_recovery_queued"])

    Tasks.agent_run_events(workspace: workspace)
    |> Enum.map(& &1["type"])
    |> assert_event_types([
      "agent_run.watchdog_recovery_queued",
      "agent_run.queued",
      "agent_run.started"
    ])
  end

  test "watchdog observes legitimate verification waits without duplicate work" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Watchdog verification wait"}, workspace: workspace)

    assert {:ok, %{agent_work: work}} =
             Tasks.start_agent_work(
               task["ref"],
               %{"message" => "Wait for verification."},
               home: home,
               workspace: workspace,
               approval: :always_approve
             )

    assert [
             %{
               "action" => "observed",
               "reason" => "legitimate_wait"
             }
           ] =
             Tasks.watchdog_scan(
               home: home,
               workspace: workspace,
               approval: :always_approve,
               stale_after_seconds: 1
             )

    assert {:ok, fetched} = Tasks.get(task["ref"], workspace: workspace)
    assert [only_work] = fetched["agent_work"]
    assert only_work["id"] == work["id"]

    assert [agent_run] = Tasks.agent_runs(workspace: workspace)
    assert agent_run["watchdog_status"] == "legitimate_wait"
  end

  test "stdio watchdog alias scans agent runs" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)
    opts = [home: home, workspace: workspace, approval: :always_approve]

    assert {:ok, task} = Tasks.create(%{"title" => "Watchdog stdio"}, workspace: workspace)

    assert {:ok, _result} =
             Tasks.start_agent_work(task["ref"], %{"message" => "Stdio watchdog."}, opts)

    assert %{"ok" => true, "result" => [%{"reason" => "legitimate_wait"}]} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "watchdog_agent_runs",
                 "params" => %{"stale_after_seconds" => 1}
               },
               opts
             )
  end

  test "complete task flow records task activity agent run and runtime events" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)
    ok_opts = [home: home, workspace: workspace, approval: :always_approve]
    block_opts = [home: home, workspace: workspace, approval: :always_deny]

    assert {:ok, task} =
             Tasks.create(
               %{"title" => "Full event flow", "priority" => "high", "labels" => ["initial"]},
               workspace: workspace
             )

    assert {:ok, target} = Tasks.create(%{"title" => "Linked target"}, workspace: workspace)

    assert {:ok, updated} =
             Tasks.update(task["ref"], %{"status" => "in_progress", "estimate" => 5},
               workspace: workspace
             )

    assert {:ok, commented} =
             Tasks.add_comment(updated["ref"], "Temporary event comment.", workspace: workspace)

    comment_id = commented["comments"] |> List.first() |> Map.fetch!("id")

    assert {:ok, without_comment} =
             Tasks.delete_comment(commented["ref"], comment_id, workspace: workspace)

    assert {:ok, labeled} =
             Tasks.add_label(without_comment["ref"], %{"name" => "events", "color" => "#16a34a"},
               workspace: workspace
             )

    assert {:ok, unlabeled} = Tasks.remove_label(labeled["ref"], "initial", workspace: workspace)

    assert {:ok, linked} =
             Tasks.add_link(unlabeled["ref"], target["ref"], "depends_on", workspace: workspace)

    link_id = linked["links"] |> List.first() |> Map.fetch!("id")
    assert {:ok, unlinked} = Tasks.remove_link(linked["ref"], link_id, workspace: workspace)

    assert {:ok, _spec} =
             Tasks.save_spec(
               unlinked["ref"],
               %{
                 "kind" => "decision",
                 "title" => "Event spec",
                 "content" => "Spec event content."
               },
               workspace: workspace
             )

    assert {:ok, %{run: first_run}} =
             Tasks.start_agent_work(task["ref"], %{"message" => "First event run."}, ok_opts)

    assert {:ok, %{run: continuation_run}} =
             Tasks.continue_agent_work(
               task["ref"],
               %{"message" => "Continuation event run."},
               ok_opts
             )

    assert {:ok, %{report: report}} =
             Tasks.route_verification(
               task["ref"],
               %{
                 "summary" => "All event checks passed.",
                 "checks" => [%{"name" => "tests", "status" => "passed"}],
                 "changed_files" => ["lib/example.ex"],
                 "evidence" => ["mix test"]
               },
               workspace: workspace
             )

    assert {:ok, blocked_task} =
             Tasks.create(%{"title" => "Blocked run event"}, workspace: workspace)

    assert {:ok, %{run: blocked_run, agent_work: blocked_work}} =
             Tasks.start_agent_work(
               blocked_task["ref"],
               %{"message" => "Force approval block."},
               block_opts
             )

    assert {:ok, final_task} = Tasks.get(task["ref"], workspace: workspace)
    assert {:ok, final_blocked_task} = Tasks.get(blocked_task["ref"], workspace: workspace)

    assert final_task["status"] == "done"
    assert report["route"]["can_finish"] == true
    assert continuation_run["resumed_from"] == first_run["id"]
    assert blocked_run["status"] == "blocked"
    assert blocked_work["status"] == "blocked"

    final_task["activity"]
    |> Enum.map(& &1["type"])
    |> assert_event_types([
      "task.created",
      "task.updated",
      "task.comment_added",
      "task.comment_deleted",
      "task.label_added",
      "task.label_removed",
      "task.link_added",
      "task.link_removed",
      "task.spec_saved",
      "agent_work.started",
      "agent_work.finished",
      "task.verification_routed"
    ])

    final_blocked_task["activity"]
    |> Enum.map(& &1["type"])
    |> assert_event_types(["task.created", "agent_work.started", "agent_work.finished"])

    agent_runs = Tasks.agent_runs(workspace: workspace)

    assert Enum.any?(
             agent_runs,
             &(&1["source"] == "task_agent_continuation" and
                 &1["previous_run_id"] == first_run["id"])
           )

    assert Enum.all?(final_task["agent_work"], &is_map(&1["liveness"]))

    Tasks.agent_run_events(workspace: workspace)
    |> Enum.map(& &1["type"])
    |> assert_event_types([
      "agent_run.queued",
      "agent_run.started",
      "agent_run.completed",
      "agent_run.failed",
      "agent_run.verification_routed"
    ])

    [first_run, continuation_run, blocked_run]
    |> Enum.flat_map(fn run -> Runs.events(run["run_dir"]) end)
    |> Enum.map(& &1["type"])
    |> assert_event_types([
      "run.created",
      "run.transitioned",
      "context.built",
      "tool.requested",
      "tool.completed",
      "tool.failed"
    ])
  end

  test "tools enforce workspace path boundaries" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:error, :path_outside_workspace} =
             Tools.execute("read_file", %{"path" => "../outside.txt"}, workspace: workspace)
  end

  test "skills parse frontmatter and select relevant skill" do
    %{home: home, workspace: workspace} = tmp_env()
    Workspace.init(workspace)
    skill_dir = Path.join([workspace, ".holtworks", "skills"])
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "repo-review.md"), """
    ---
    name: repo-review
    description: Review a codebase and produce architecture notes.
    triggers:
      - architecture
      - review repo
    risk: read
    ---

    Use fast file search first.
    """)

    skills = Skills.relevant("please review repo architecture", home: home, workspace: workspace)

    assert [%{name: "repo-review", risk: "read"}] = skills
  end

  test "agent skill tools save load update list and run scripts" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, save_execution} =
             Tasks.execute_action(
               "save_skill",
               %{
                 "name" => "Repo Review",
                 "slug" => "repo-review",
                 "description" => "Review a repository and summarize architecture.",
                 "body" => "1. Run `list_files`.\n2. Summarize the architecture.",
                 "triggers" => ["review repo", "architecture"],
                 "scripts" => %{"hello.sh" => "echo skill:$1\n"}
               },
               workspace: workspace,
               approval: :always_approve
             )

    assert save_execution["status"] == "ok"
    assert save_execution["result"]["slug"] == "repo-review"
    assert save_execution["result"]["version"] == "1"
    assert save_execution["result"]["scripts"] == ["hello.sh"]

    assert {:ok, list_execution} =
             Tasks.execute_action("list_skills", %{"query" => "architecture"},
               workspace: workspace
             )

    assert [%{"slug" => "repo-review"}] = list_execution["result"]["skills"]

    assert {:ok, load_execution} =
             Tasks.execute_action("load_skill", %{"slug" => "repo-review"}, workspace: workspace)

    assert load_execution["result"]["content"] =~ "Summarize the architecture"

    assert {:ok, update_execution} =
             Tasks.execute_action(
               "update_skill",
               %{
                 "slug" => "repo-review",
                 "description" => "Review code architecture quickly.",
                 "body" => "Updated body for repeated repo reviews.",
                 "scripts" => %{"hello.sh" => "echo updated:$1\n"}
               },
               workspace: workspace,
               approval: :always_approve
             )

    assert update_execution["result"]["version"] == "2"
    assert update_execution["result"]["description"] == "Review code architecture quickly."
    assert update_execution["result"]["content"] =~ "Updated body"

    assert {:ok, script_execution} =
             Tasks.execute_action(
               "run_skill_script",
               %{"skill_slug" => "repo-review", "script_name" => "hello.sh", "args" => ["ok"]},
               workspace: workspace,
               approval: :always_approve
             )

    assert script_execution["result"]["exit_code"] == 0
    assert script_execution["result"]["output"] =~ "updated:ok"

    catalog =
      Tasks.action_catalog(%{"action_provider_ids" => ["workspace"]}, workspace: workspace)

    names = Enum.map(catalog, & &1["name"])
    assert "list_skills" in names
    assert "load_skill" in names
    assert "run_skill_script" in names

    run_entry = Enum.find(catalog, &(&1["name"] == "run_skill_script"))
    assert run_entry["requires_approval"] == true
    assert run_entry["input_schema"]["required"] == ["skill_slug", "script_name"]

    assert %{"ok" => true, "result" => loaded} =
             Bridge.Stdio.handle_request(
               %{"method" => "skills/load", "params" => %{"slug" => "repo-review"}},
               workspace: workspace
             )

    assert loaded["content"] =~ "Updated body"
  end

  test "memory saves and searches local facts" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, entry} = Memory.save("decision", "Use a local gateway", workspace: workspace)
    assert entry["kind"] == "decision"

    assert [found] = Memory.search("gateway", workspace: workspace)
    assert found["text"] == "Use a local gateway"
  end

  test "scoped user memory tools remember search list and forget" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, remember_execution} =
             Tasks.execute_action(
               "remember_about_user",
               %{
                 "user_id" => "user_1",
                 "summary" => "The user prefers compact implementation notes.",
                 "category" => "preference"
               },
               workspace: workspace
             )

    assert remember_execution["status"] == "ok"
    assert remember_execution["result"]["schema_version"] == "holtworks_user_memory/v1"
    assert remember_execution["result"]["scope"] == "user"
    assert remember_execution["result"]["user_id"] == "user_1"

    assert {:ok, list_execution} =
             Tasks.execute_action(
               "list_user_memories",
               %{"user_id" => "user_1", "category" => "preference"},
               workspace: workspace
             )

    assert [%{"summary" => "The user prefers compact implementation notes."}] =
             list_execution["result"]["memories"]

    assert {:ok, search_execution} =
             Tasks.execute_action(
               "search_user_memory",
               %{"user_id" => "user_1", "query" => "compact"},
               workspace: workspace
             )

    assert [%{"category" => "preference"}] = search_execution["result"]["matches"]

    assert {:ok, forget_execution} =
             Tasks.execute_action(
               "forget_about_user",
               %{"user_id" => "user_1", "substring" => "compact implementation"},
               workspace: workspace
             )

    assert forget_execution["result"]["forgotten_count"] == 1

    assert {:ok, empty_list} =
             Tasks.execute_action("list_user_memories", %{"user_id" => "user_1"},
               workspace: workspace
             )

    assert empty_list["result"]["memories"] == []
  end

  test "scoped project memory tools save recall and read plans and research" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, note_execution} =
             Tasks.execute_action(
               "remember_for_project",
               %{
                 "project_id" => "project_1",
                 "summary" => "Use a local-first runtime boundary.",
                 "category" => "structure"
               },
               workspace: workspace
             )

    assert note_execution["result"]["kind"] == "note"

    assert {:ok, plan_execution} =
             Tasks.execute_action(
               "save_plan",
               %{
                 "project_id" => "project_1",
                 "title" => "Migration plan",
                 "body" => "Move scoped memory tools before implementing delegation",
                 "category" => "general"
               },
               workspace: workspace
             )

    plan_id = plan_execution["result"]["id"]
    assert plan_execution["result"]["kind"] == "plan"

    assert {:ok, research_execution} =
             Tasks.execute_action(
               "save_research",
               %{
                 "project_id" => "project_1",
                 "title" => "Memory research",
                 "body" => "Inktrail separates user and project memory tools.",
                 "category" => "structure",
                 "sources" => ["inktrail/actions/project_memory"]
               },
               workspace: workspace
             )

    assert research_execution["result"]["kind"] == "research"
    assert research_execution["result"]["sources"] == ["inktrail/actions/project_memory"]

    assert {:ok, recall_execution} =
             Tasks.execute_action(
               "recall_project_memory",
               %{"project_id" => "project_1", "query" => "delegation", "kind" => "plan"},
               workspace: workspace
             )

    assert [
             %{
               "id" => ^plan_id,
               "kind" => "plan",
               "title" => "Migration plan",
               "snippet" => snippet
             }
           ] = recall_execution["result"]["memories"]

    assert snippet =~ "delegation"

    assert {:ok, read_execution} =
             Tasks.execute_action(
               "read_project_memory",
               %{"project_id" => "project_1", "id" => plan_id},
               workspace: workspace
             )

    assert read_execution["result"]["body"] =~ "scoped memory"

    catalog =
      Tasks.action_catalog(%{"action_provider_ids" => ["workspace"]}, workspace: workspace)

    names = Enum.map(catalog, & &1["name"])
    assert "remember_about_user" in names
    assert "recall_project_memory" in names
    assert "save_research" in names
  end

  test "local model adapter returns normalized chat response" do
    assert {:ok, response} =
             Models.chat(
               %{"type" => "local", "model" => "local-planner"},
               [%{"role" => "user", "content" => "plan this repo"}]
             )

    assert response["provider"] == "local"
    assert response["content"] =~ "plan this repo"
  end

  test "cli llm test works with local provider" do
    %{home: home} = tmp_env()

    output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "llm",
                 "test",
                 "local",
                 "--home",
                 home,
                 "--prompt",
                 "plan this repo"
               ]) == 0
      end)

    assert output =~ "Provider: local"
    assert output =~ "Local planner received"
  end

  test "cli llm test reports missing openrouter key clearly" do
    %{home: home} = tmp_env()
    previous = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")
    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous) end)

    output =
      capture_io(:stderr, fn ->
        assert HoltWorks.CLI.main(["llm", "test", "openrouter", "--home", home]) == 78
      end)

    assert output =~ "Missing OPENROUTER_API_KEY"
  end

  test "env loader imports provider key without overwriting existing env" do
    %{workspace: workspace} = tmp_env()
    previous = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")
    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous) end)
    env_file = Path.join(workspace, ".env")
    File.write!(env_file, "OPENROUTER_API_KEY=test-key\n")

    assert :ok = Env.load(workspace: workspace)
    assert System.get_env("OPENROUTER_API_KEY") == "test-key"

    File.write!(env_file, "OPENROUTER_API_KEY=second-key\n")
    assert :ok = Env.load(workspace: workspace)
    assert System.get_env("OPENROUTER_API_KEY") == "test-key"
  end

  test "openrouter adapter sends compatible chat completion request" do
    previous = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "test-key")
    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous) end)
    test_pid = self()

    post_json = fn url, headers, body, api_key ->
      send(test_pid, {:openrouter_request, url, headers, body, api_key})

      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "finish_reason" => "tool_calls",
               "message" => %{
                 "content" => "# NEXT STEPS\n\nGenerated by OpenRouter.",
                 "tool_calls" => [
                   %{
                     "id" => "call_read_file",
                     "type" => "function",
                     "function" => %{
                       "name" => "read_file",
                       "arguments" => Jason.encode!(%{"path" => "README.md"})
                     }
                   }
                 ]
               }
             }
           ]
         }
       }}
    end

    read_file_tool = %{
      type: "function",
      function: %{
        name: "read_file",
        parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
      }
    }

    assert {:ok, response} =
             Models.chat(
               %{
                 "id" => "openrouter",
                 "type" => "openrouter",
                 "model" => "openai/gpt-4o-mini",
                 "api_key_env" => "OPENROUTER_API_KEY",
                 "base_url" => "https://openrouter.ai/api/v1",
                 "http_referer" => "https://holtworks.ai",
                 "app_title" => "HoltWorks"
               },
               [%{"role" => "user", "content" => "plan this repo"}],
               post_json: post_json,
               tools: [read_file_tool],
               tool_choice: "auto"
             )

    assert response["provider"] == "openrouter"
    assert response["content"] =~ "Generated by OpenRouter"
    assert [%{"function" => %{"name" => "read_file"}}] = response["tool_calls"]
    assert response["finish_reason"] == "tool_calls"

    assert_received {:openrouter_request, "https://openrouter.ai/api/v1/chat/completions",
                     headers, body, "test-key"}

    assert {"HTTP-Referer", "https://holtworks.ai"} in headers
    assert {"X-Title", "HoltWorks"} in headers
    assert body.model == "openai/gpt-4o-mini"
    assert [%{"role" => "user", "content" => "plan this repo"}] = body.messages
    assert body.tools == [read_file_tool]
    assert body.tool_choice == "auto"
  end

  test "runtime uses openrouter response as the plan when configured" do
    %{home: home, workspace: workspace} = tmp_env()
    previous = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "test-key")
    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous) end)
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    providers = Config.default_providers() |> Map.put("default_provider", "openrouter")
    Config.save_providers(home, providers)

    post_json = fn _url, _headers, _body, _api_key ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{
                 "content" => "# NEXT STEPS\n\nLLM generated plan from OpenRouter."
               }
             }
           ]
         }
       }}
    end

    assert {:ok, %{run: run, output: output}} =
             Runtime.run("inspect this folder",
               home: home,
               workspace: workspace,
               approval: :always_approve,
               post_json: post_json
             )

    assert run["status"] == "completed"
    assert output =~ "LLM generated plan from OpenRouter"
    assert File.read!(Path.join(workspace, "NEXT_STEPS.md")) =~ "LLM generated plan"

    events = Runs.events(run["run_dir"])
    assert Enum.any?(events, &(Map.get(&1, "type") == "model.requested"))
    assert Enum.any?(events, &(Map.get(&1, "type") == "model.completed"))
  end

  test "state machine enforces structured transitions" do
    assert {:ok, "queued"} = StateMachine.transition("created", "queued")
    assert {:ok, "running"} = StateMachine.transition("queued", "running")

    assert {:error, {:invalid_transition, "completed", "running"}} =
             StateMachine.transition("completed", "running")
  end

  test "stdio bridge handles status and tools list" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)

    assert %{"ok" => true, "result" => status} =
             Bridge.Stdio.handle_request(%{"method" => "status"},
               home: home,
               workspace: workspace
             )

    assert status["workspace"] == workspace

    assert %{"ok" => true, "result" => tools} =
             Bridge.Stdio.handle_request(%{"method" => "tools/list"},
               home: home,
               workspace: workspace
             )

    assert Enum.any?(tools, &(&1["name"] == "write_file"))
  end

  test "stdio bridge exposes task action parity methods" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)
    opts = [home: home, workspace: workspace, approval: :always_approve]

    assert %{"ok" => true, "result" => source} =
             Bridge.Stdio.handle_request(
               %{"method" => "tasks/create", "params" => %{"title" => "Bridge source"}},
               opts
             )

    assert %{"ok" => true, "result" => target} =
             Bridge.Stdio.handle_request(
               %{"method" => "tasks/create", "params" => %{"title" => "Bridge target"}},
               opts
             )

    assert %{"ok" => true, "result" => labeled} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/add_label",
                 "params" => %{"ref" => source["ref"], "name" => "bridge"}
               },
               opts
             )

    assert [%{"name" => "bridge"}] = labeled["labels"]

    assert %{"ok" => true, "result" => linked} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/add_link",
                 "params" => %{
                   "ref" => source["ref"],
                   "target_ref" => target["ref"],
                   "type" => "tracks"
                 }
               },
               opts
             )

    assert [%{"type" => "tracks"}] = linked["links"]

    assert %{"ok" => true, "result" => spec} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/save_spec",
                 "params" => %{
                   "ref" => source["ref"],
                   "kind" => "decision",
                   "title" => "Bridge decision",
                   "content" => "Bridge spec content."
                 }
               },
               opts
             )

    assert %{"ok" => true, "result" => [listed_spec]} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/list_specs",
                 "params" => %{"ref" => source["ref"], "include_content" => true}
               },
               opts
             )

    assert listed_spec["content"] == "Bridge spec content."

    assert %{"ok" => true, "result" => fetched_spec} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/get_spec",
                 "params" => %{"spec_id" => spec["id"], "ref" => source["ref"]}
               },
               opts
             )

    assert fetched_spec["content"] == "Bridge spec content."

    assert %{"ok" => true, "result" => run_result} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/run",
                 "params" => %{"ref" => source["ref"], "message" => "Bridge first run."}
               },
               opts
             )

    assert %{"ok" => true, "result" => continue_result} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/continue",
                 "params" => %{"ref" => source["ref"], "message" => "Bridge continuation."}
               },
               opts
             )

    assert continue_result[:run]["resumed_from"] == run_result[:run]["id"]
    assert continue_result[:agent_work]["iteration"] == 2

    assert %{"ok" => true, "result" => memory_spec} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/save_teammate_memory",
                 "params" => %{
                   "ref" => source["ref"],
                   "kind" => "workflow_pattern",
                   "title" => "Bridge workflow",
                   "observed_pattern" => "Bridge callers load runtime before work.",
                   "source_spec_ids" => [spec["id"]]
                 }
               },
               opts
             )

    assert %{"ok" => true, "result" => %{"text" => runtime_text}} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/load_teammate_runtime",
                 "params" => %{"ref" => source["ref"]}
               },
               opts
             )

    assert runtime_text =~ "Bridge workflow"

    assert %{"ok" => true, "result" => read_memory} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/read_memory_artifact",
                 "params" => %{"artifact_ref" => memory_spec["id"]}
               },
               opts
             )

    assert read_memory["content"] =~ "Bridge callers load runtime before work."
  end

  test "stdio bridge accepts Inktrail MCP-style task method aliases" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)
    opts = [home: home, workspace: workspace, approval: :always_approve]

    assert %{"ok" => true, "result" => task} =
             Bridge.Stdio.handle_request(
               %{"method" => "create_task", "params" => %{"title" => "Alias task"}},
               opts
             )

    assert %{"ok" => true, "result" => fetched} =
             Bridge.Stdio.handle_request(
               %{"method" => "get_task", "params" => %{"task_id" => task["ref"]}},
               opts
             )

    assert fetched["id"] == task["id"]

    assert %{"ok" => true, "result" => updated} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "update_task",
                 "params" => %{"task_id" => task["ref"], "priority" => "urgent"}
               },
               opts
             )

    assert updated["priority"] == "urgent"

    assert %{"ok" => true, "result" => spec} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "save_task_spec",
                 "params" => %{
                   "task_id" => task["ref"],
                   "kind" => "decision",
                   "title" => "Alias decision",
                   "content" => "Alias spec content."
                 }
               },
               opts
             )

    assert %{"ok" => true, "result" => [listed_spec]} =
             Bridge.Stdio.handle_request(
               %{"method" => "list_task_specs", "params" => %{"task_id" => task["ref"]}},
               opts
             )

    assert listed_spec["id"] == spec["id"]

    assert %{"ok" => true, "result" => run_result} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "start_agent_work",
                 "params" => %{"task_id" => task["ref"], "message" => "Alias run."}
               },
               opts
             )

    assert run_result[:run]["status"] == "completed"

    assert %{"ok" => true, "result" => verify_result} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "route_verification_review",
                 "params" => %{
                   "task_id" => task["ref"],
                   "summary" => "Alias verification passed.",
                   "checks" => [%{"name" => "tests", "status" => "passed"}]
                 }
               },
               opts
             )

    assert verify_result[:report]["route"]["can_finish"] == true

    assert %{"ok" => true, "result" => graph} =
             Bridge.Stdio.handle_request(
               %{"method" => "create_task_graph", "params" => %{"task_id" => task["ref"]}},
               opts
             )

    assert %{"ok" => true, "result" => completed_graph} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "complete_task_graph_node",
                 "params" => %{
                   "graph_id" => graph["id"],
                   "node_key" => "plan",
                   "summary" => "Plan node complete."
                 }
               },
               opts
             )

    assert graph_node(completed_graph, "work")["status"] == "scheduled"

    assert %{"ok" => true, "result" => [listed_graph]} =
             Bridge.Stdio.handle_request(
               %{"method" => "list_task_graphs", "params" => %{"task_id" => task["ref"]}},
               opts
             )

    assert listed_graph["id"] == graph["id"]

    assert %{"ok" => true, "result" => evidence_contract} =
             Bridge.Stdio.handle_request(
               %{"method" => "get_evidence_contract", "params" => %{"task_id" => task["ref"]}},
               opts
             )

    assert evidence_contract["schema_version"] == "holtworks_evidence_contract/v1"

    assert %{"ok" => true, "result" => verifier_route} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "plan_verifier_route",
                 "params" => %{"task_id" => task["ref"], "graph_id" => graph["id"]}
               },
               opts
             )

    assert verifier_route[:route]["child_agent_contract"]["job_contract"]["gate_tool"] ==
             "route_verification_review"

    assert %{"ok" => true, "result" => tool_session} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "task_tool_session",
                 "params" => %{"task_id" => task["ref"], "disabled_tools" => ["write_file"]}
               },
               opts
             )

    refute "write_file" in tool_session["direct_tools"]

    assert %{"ok" => true, "result" => tool_route} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "route_task_tool",
                 "params" => %{"task_id" => task["ref"], "tool_name" => "get_task"}
               },
               opts
             )

    assert tool_route["status"] == "accepted"
    assert tool_route["action_contract"]["effect_scope"] == "read_only"

    assert %{"ok" => true, "result" => action_contract} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "action_contract",
                 "params" => %{"task_id" => task["ref"], "tool_name" => "get_task"}
               },
               opts
             )

    assert action_contract["schema_version"] == "holtworks_action_contract/v1"
    assert action_contract["effect_scope"] == "read_only"

    assert %{"ok" => true, "result" => plan_contract} =
             Bridge.Stdio.handle_request(
               %{"method" => "plan_contract", "params" => %{"task_id" => task["ref"]}},
               opts
             )

    assert plan_contract["schema_version"] == "holtworks_plan_contract/v1"

    assert %{"ok" => true, "result" => plan_gate} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "plan_gate",
                 "params" => %{"task_id" => task["ref"], "tool_name" => "get_task"}
               },
               opts
             )

    assert plan_gate["action"] == "approved"

    assert %{"ok" => true, "result" => preflight} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "action_preflight",
                 "params" => %{"task_id" => task["ref"], "tool_name" => "get_task"}
               },
               opts
             )

    assert preflight["result"] == "passed"

    assert %{"ok" => true, "result" => consequence_gate} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "consequence_gate",
                 "params" => %{"task_id" => task["ref"], "tool_name" => "get_task"}
               },
               opts
             )

    assert consequence_gate["action"] == "approved"

    assert %{"ok" => true, "result" => envelope} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "action_runtime_envelope",
                 "params" => %{"task_id" => task["ref"], "tool_name" => "get_task"}
               },
               opts
             )

    assert envelope["execution_decision"] == "execute"

    assert %{"ok" => true, "result" => completed_envelope} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "complete_action_runtime_envelope",
                 "params" => %{
                   "envelope" => envelope,
                   "result" => %{"status" => "ok", "preview" => "stdio runtime completed"}
                 }
               },
               opts
             )

    assert completed_envelope["runtime_status"] == "completed_continue"

    assert %{"ok" => true, "result" => approval_request} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "action_approval_request",
                 "params" => %{
                   "task_id" => task["ref"],
                   "tool_name" => "run_command",
                   "allow_workspace_durable" => true
                 }
               },
               opts
             )

    assert approval_request["status"] == "pending"

    assert %{"ok" => true, "result" => resolved_request} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "resolve_action_approval_request",
                 "params" => %{
                   "approval_request_id" => approval_request["approval_request_id"],
                   "decision" => "approved",
                   "decided_by" => "stdio"
                 }
               },
               opts
             )

    assert resolved_request["status"] == "approved"

    assert %{"ok" => true, "result" => evidence_ledger} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "action_evidence_ledger",
                 "params" => %{
                   "task_id" => task["ref"],
                   "tool_name" => "get_task",
                   "result_status" => "ok",
                   "result_preview" => "stdio ledger"
                 }
               },
               opts
             )

    assert evidence_ledger["schema_version"] == "holtworks_evidence_ledger/v1"
    assert evidence_ledger["coverage"]["has_observation"] == true

    assert %{"ok" => true, "result" => memory_artifact} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "record_task_memory_artifact",
                 "params" => %{
                   "task_id" => task["ref"],
                   "kind" => "handoff",
                   "title" => "Alias memory",
                   "content" => "Alias exact memory content."
                 }
               },
               opts
             )

    assert memory_artifact["schema_version"] == "holtworks_task_memory_artifact/v1"

    assert %{"ok" => true, "result" => memory_context} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "task_memory_context",
                 "params" => %{"task_id" => task["ref"], "estimated_input_tokens" => 1000}
               },
               opts
             )

    assert memory_context["schema_version"] == "holtworks_task_memory_context_packet/v1"
    assert memory_artifact["artifact_ref"] in memory_context["artifact_refs"]

    assert %{"ok" => true, "result" => context_budget} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "context_budget",
                 "params" => %{"task_id" => task["ref"], "estimated_input_tokens" => 1000}
               },
               opts
             )

    assert context_budget["schema_version"] == "holtworks_context_budget_governor/v1"
    assert context_budget["action"] == "send"

    assert %{"ok" => true, "result" => continuation_packet} =
             Bridge.Stdio.handle_request(
               %{"method" => "continuation_packet", "params" => %{"task_id" => task["ref"]}},
               opts
             )

    assert continuation_packet["schema_version"] == "holtworks_continuation_packet/v1"
    assert continuation_packet["previous_runtime_run_id"] == run_result[:run]["id"]

    assert %{"ok" => true, "result" => capability_entry} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "capability_registry",
                 "params" => %{"tool_name" => "get_task"}
               },
               opts
             )

    assert capability_entry["schema_version"] == "holtworks_capability_registry_entry/v1"

    assert %{"ok" => true, "result" => capability_contract} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "capability_contract",
                 "params" => %{"task_id" => task["ref"], "tool_name" => "get_task"}
               },
               opts
             )

    assert capability_contract["schema_version"] == "holtworks_capability_contract/v1"

    assert %{"ok" => true, "result" => capability_route} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "capability_route",
                 "params" => %{"task_id" => task["ref"], "tool_name" => "get_task"}
               },
               opts
             )

    assert capability_route["schema_version"] == "holtworks_capability_route/v1"
    assert capability_route["execution_mode"] in ["persisted_agent", "ephemeral_sub_agent"]

    assert %{"ok" => true, "result" => generic_plan} =
             Bridge.Stdio.handle_request(
               %{"method" => "generic_plan", "params" => %{"task_id" => task["ref"]}},
               opts
             )

    assert generic_plan["schema_version"] == "holtworks_generic_work_graph/v1"

    assert Enum.map(generic_plan["nodes"], & &1["phase"]) ==
             ~w(research propose act verify repair)
  end

  test "cli run completes with explicit approval flag" do
    %{home: home, workspace: workspace} = tmp_env()

    output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "run",
                 "--yes",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "inspect this folder and create a short implementation plan"
               ]) == 0
      end)

    assert output =~ "# NEXT STEPS"
    assert output =~ "Status: completed"
    assert File.exists?(Path.join(workspace, "NEXT_STEPS.md"))
  end

  test "cli task flow creates lists runs and verifies a task" do
    %{home: home, workspace: workspace} = tmp_env()

    create_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "create",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--priority",
                 "high",
                 "Inspect workspace"
               ]) == 0
      end)

    assert create_output =~ "Created HW-01"

    list_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "list",
                 "--home",
                 home,
                 "--workspace",
                 workspace
               ]) == 0
      end)

    assert list_output =~ "HW-01 todo high Inspect workspace"

    run_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "run",
                 "--yes",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)

    assert run_output =~ "Task status: waiting"
    assert run_output =~ "Run status: completed"

    continue_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "continue",
                 "--yes",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "Continue the task run."
               ]) == 0
      end)

    assert continue_output =~ "Continuation: 2"
    assert continue_output =~ "Run status: completed"

    verify_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "verify",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--check",
                 "tests:passed",
                 "--summary",
                 "Checks passed.",
                 "HW-01"
               ]) == 0
      end)

    assert verify_output =~ "Verification routed: HW-01 -> done"
  end

  test "cli task graph commands create show and complete graph nodes" do
    %{home: home, workspace: workspace} = tmp_env()

    capture_io(fn ->
      assert HoltWorks.CLI.main([
               "tasks",
               "create",
               "--home",
               home,
               "--workspace",
               workspace,
               "Graph CLI task"
             ]) == 0
    end)

    graph =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "graph",
                 "create",
                 "--json",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)
      |> Jason.decode!()

    assert graph_node(graph, "plan")["status"] == "scheduled"

    completed =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "graph",
                 "complete",
                 "--json",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--summary",
                 "Plan complete.",
                 graph["id"],
                 "plan"
               ]) == 0
      end)
      |> Jason.decode!()

    assert graph_node(completed, "work")["status"] == "scheduled"

    list_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "graph",
                 "list",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)

    assert list_output =~ graph["id"]

    show_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "graph",
                 "show",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 graph["id"]
               ]) == 0
      end)

    assert show_output =~ "Gate: blocked"

    evidence_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "evidence-contract",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)

    assert evidence_output =~ "Evidence contract: generic"

    verifier_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "verifier",
                 "route",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--graph-id",
                 graph["id"],
                 "HW-01"
               ]) == 0
      end)

    assert verifier_output =~ "Verifier route:"

    tool_session_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "tool-session",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--disabled-tool",
                 "write_file",
                 "HW-01"
               ]) == 0
      end)

    assert tool_session_output =~ "Tool session:"
    refute tool_session_output =~ "write_file"

    tool_route_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "tool",
                 "route",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "run_command"
               ]) == 0
      end)

    assert tool_route_output =~ "Status: accepted"
    assert tool_route_output =~ "Requires approval: true"

    action_contract_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "action-contract",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "get_task"
               ]) == 0
      end)

    assert action_contract_output =~ "Action contract:"
    assert action_contract_output =~ "Effect scope: read_only"

    plan_contract_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "plan-contract",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)

    assert plan_contract_output =~ "Plan contract:"
    assert plan_contract_output =~ "Effect scopes: read_only"

    plan_gate_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "plan-gate",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "get_task"
               ]) == 0
      end)

    assert plan_gate_output =~ "Action: approved"

    preflight_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "preflight",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "get_task"
               ]) == 0
      end)

    assert preflight_output =~ "Result: passed"

    consequence_gate_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "consequence-gate",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "get_task"
               ]) == 0
      end)

    assert consequence_gate_output =~ "Action: approved"

    action_envelope_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "action-envelope",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "get_task"
               ]) == 0
      end)

    assert action_envelope_output =~ "Execution decision: execute"

    approval_request_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "approval-request",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--allow-workspace-durable",
                 "HW-01",
                 "run_command"
               ]) == 0
      end)

    assert approval_request_output =~ "Approval request:"
    assert approval_request_output =~ "Status: pending"

    evidence_ledger_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "evidence-ledger",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--result-status",
                 "ok",
                 "--result-preview",
                 "task read",
                 "HW-01",
                 "get_task"
               ]) == 0
      end)

    assert evidence_ledger_output =~ "Evidence ledger:"
    assert evidence_ledger_output =~ "Evidence types:"

    memory_artifact_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "memory-artifact",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--kind",
                 "handoff",
                 "--title",
                 "CLI memory",
                 "--content",
                 "CLI exact memory content.",
                 "HW-01"
               ]) == 0
      end)

    assert memory_artifact_output =~ "Task memory artifact:"

    memory_context_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "memory-context",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)

    assert memory_context_output =~ "Task memory context:"
    assert memory_context_output =~ "Artifacts:"

    context_budget_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "context-budget",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--estimated-input-tokens",
                 "1000",
                 "HW-01"
               ]) == 0
      end)

    assert context_budget_output =~ "Context budget:"
    assert context_budget_output =~ "Action: send"

    capability_registry_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "capability-registry",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "get_task"
               ]) == 0
      end)

    assert capability_registry_output =~ "Capability registry:"
    assert capability_registry_output =~ "Effect scope: read_only"

    capability_contract_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "capability-contract",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "get_task"
               ]) == 0
      end)

    assert capability_contract_output =~ "Capability contract:"
    assert capability_contract_output =~ "Required tools: get_task"

    capability_route_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "capability-route",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 "get_task"
               ]) == 0
      end)

    assert capability_route_output =~ "Capability route:"

    generic_plan_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "generic-plan",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)

    assert generic_plan_output =~ "Generic plan:"
    assert generic_plan_output =~ "Phases: research, propose, act, verify, repair"
  end

  test "cli task parity commands manage labels links comments and specs" do
    %{home: home, workspace: workspace} = tmp_env()

    capture_io(fn ->
      assert HoltWorks.CLI.main([
               "tasks",
               "create",
               "--home",
               home,
               "--workspace",
               workspace,
               "Source task"
             ]) == 0

      assert HoltWorks.CLI.main([
               "tasks",
               "create",
               "--home",
               home,
               "--workspace",
               workspace,
               "Target task"
             ]) == 0
    end)

    label_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "label",
                 "add",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--color",
                 "#16a34a",
                 "HW-01",
                 "frontend"
               ]) == 0
      end)

    assert label_output =~ "frontend(#16a34a)"

    link_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "link",
                 "add",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--type",
                 "depends_on",
                 "HW-01",
                 "HW-02"
               ]) == 0
      end)

    assert link_output =~ "Links on HW-01: 1"

    show_json =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "show",
                 "--json",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)

    task = Jason.decode!(show_json)
    [%{"id" => link_id}] = task["links"]

    remove_link_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "link",
                 "remove",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 link_id
               ]) == 0
      end)

    assert remove_link_output =~ "Links on HW-01: 0"

    capture_io(fn ->
      assert HoltWorks.CLI.main([
               "tasks",
               "comment",
               "--home",
               home,
               "--workspace",
               workspace,
               "HW-01",
               "temporary comment"
             ]) == 0
    end)

    commented =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "show",
                 "--json",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)
      |> Jason.decode!()

    [%{"id" => comment_id}] = commented["comments"]

    delete_comment_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "comment",
                 "delete",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01",
                 comment_id
               ]) == 0
      end)

    assert delete_comment_output =~ "Comment deleted from HW-01"

    spec_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "spec",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--kind",
                 "handoff",
                 "--title",
                 "CLI handoff",
                 "--content",
                 "CLI handoff content.",
                 "HW-01"
               ]) == 0
      end)

    assert spec_output =~ "Saved handoff spec"

    specs_json =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "specs",
                 "list",
                 "--json",
                 "--include-content",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "HW-01"
               ]) == 0
      end)

    [spec] = Jason.decode!(specs_json)
    assert spec["content"] == "CLI handoff content."

    get_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "specs",
                 "get",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 "--task",
                 "HW-01",
                 spec["id"]
               ]) == 0
      end)

    assert get_output =~ "CLI handoff content."
  end

  test "executable task actions route then persist task changes" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Executable action flow"}, workspace: workspace)

    assert {:ok, create_execution} =
             Tasks.execute_action(
               "create_task",
               %{"title" => "Created through action", "priority" => "high"},
               workspace: workspace
             )

    assert create_execution["status"] == "ok"
    assert create_execution["result"]["title"] == "Created through action"
    assert create_execution["result"]["priority"] == "high"

    assert {:ok, comment_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "add_comment",
               %{"body" => "created through executable action"},
               workspace: workspace
             )

    assert comment_execution["schema_version"] == "holtworks_action_execution/v1"
    assert comment_execution["status"] == "ok"
    assert get_in(comment_execution, ["route", "status"]) == "accepted"

    assert [%{"body" => "created through executable action"}] =
             get_in(comment_execution, ["result", "comments"])

    assert {:ok, update_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "update_task",
               %{"status" => "in_progress"},
               workspace: workspace
             )

    assert update_execution["result"]["status"] == "in_progress"

    assert {:ok, priority_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "set_priority",
               %{"priority" => "urgent"},
               workspace: workspace
             )

    assert priority_execution["result"]["priority"] == "urgent"

    assert {:ok, estimate_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "set_estimate",
               %{"estimate" => 5},
               workspace: workspace
             )

    assert estimate_execution["result"]["estimate"] == 5

    assert {:error, rejected} =
             Tasks.execute_task_action(
               task["ref"],
               "update_task",
               %{"status" => "done", "disabled_tools" => ["update_task"]},
               workspace: workspace
             )

    assert rejected["status"] == "rejected"
    assert rejected["reason"] == "tool_disabled_for_session"
  end

  test "meta actions expose schemas and execute only safe nested task tools" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)

    assert {:ok, task} =
             Tasks.create(%{"title" => "Executable meta action flow"}, workspace: workspace)

    assert {:ok, search_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "search_tools",
               %{"effect_scopes" => ["task_durable"]},
               workspace: workspace
             )

    assert Enum.any?(
             get_in(search_execution, ["result", "actions"]),
             &(&1["name"] == "update_task")
           )

    assert {:ok, schema_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "get_tool_schema",
               %{"tool_name" => "add_comment"},
               workspace: workspace
             )

    assert get_in(schema_execution, ["result", "action", "name"]) == "add_comment"

    assert get_in(schema_execution, ["result", "action", "arguments_schema", "required"]) == [
             "body"
           ]

    assert {:error, unsafe_nested_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "execute_tool",
               %{
                 "tool_name" => "add_label",
                 "arguments" => %{"name" => "nested", "color" => "#0f766e"}
               },
               workspace: workspace
             )

    assert unsafe_nested_execution["status"] == "error"
    assert unsafe_nested_execution["reason"] == "unsafe_nested_effect_scope:task_durable"

    assert {:ok, todo_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "execute_tool",
               %{
                 "tool_name" => "todo_write",
                 "arguments" => %{
                   "todos" => [
                     %{"content" => "Check action safety", "status" => "in_progress"}
                   ]
                 }
               },
               workspace: workspace
             )

    assert get_in(todo_execution, ["result", "status"]) == "ok"
    assert get_in(todo_execution, ["result", "result", "status"]) == "updated"

    assert [
             %{
               "content" => "Check action safety",
               "status" => "in_progress",
               "activeForm" => "Check action safety",
               "active_form" => "Check action safety"
             }
           ] = get_in(todo_execution, ["result", "result", "todos"])

    assert {:ok, read_todo_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "todo_read",
               %{
                 "task_tool_session" => %{
                   "todos" => [
                     %{"content" => "Stored in session", "status" => "pending"}
                   ]
                 }
               },
               workspace: workspace
             )

    assert [%{"content" => "Stored in session"}] = read_todo_execution["result"]["todos"]
    assert read_todo_execution["result"]["text"] == "- [ ] Stored in session"

    assert {:error, invalid_todo_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "todo_write",
               %{"todos" => [%{"status" => "pending"}]},
               workspace: workspace
             )

    assert invalid_todo_execution["status"] == "error"
    assert invalid_todo_execution["reason"] == "Each todo needs a non-empty `content` string."

    assert {:error, missing_todos_execution} =
             Tasks.execute_task_action(task["ref"], "todo_write", %{}, workspace: workspace)

    assert missing_todos_execution["status"] == "error"
    assert missing_todos_execution["reason"] == "todos is required."
  end

  test "task session meta tools report connections and route workbench reads" do
    %{workspace: workspace} = tmp_env()
    Workspace.init(workspace)
    File.write!(Path.join(workspace, "WORKBENCH.md"), "Workbench context")

    assert {:ok, task} =
             Tasks.create(%{"title" => "Workbench meta action flow"}, workspace: workspace)

    session_attrs = %{
      "connected_accounts" => %{"github" => %{"connected_account_id" => "acct_github"}},
      "workbench" => %{"enabled" => true, "runtime" => "workspace"}
    }

    assert {:ok, connection_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "manage_connection",
               Map.put(session_attrs, "action", "request"),
               workspace: workspace
             )

    assert connection_execution["status"] == "ok"

    assert get_in(connection_execution, [
             "result",
             "connected_accounts",
             "github",
             "connected_account_id"
           ]) ==
             "acct_github"

    assert get_in(connection_execution, ["result", "status"]) ==
             "requires_user_initiated_connection_flow"

    assert {:ok, workbench_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "use_workbench",
               session_attrs,
               workspace: workspace
             )

    assert get_in(workbench_execution, ["result", "status"]) == "available"
    assert get_in(workbench_execution, ["result", "workbench", "runtime"]) == "workspace"

    assert {:ok, read_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "use_workbench",
               Map.merge(session_attrs, %{
                 "tool_name" => "read_file",
                 "arguments" => %{"path" => "WORKBENCH.md"}
               }),
               workspace: workspace
             )

    assert get_in(read_execution, ["result", "status"]) == "executed"
    assert get_in(read_execution, ["result", "tool_execution", "tool_name"]) == "read_file"

    assert get_in(read_execution, ["result", "tool_execution", "result", "content"]) ==
             "Workbench context"

    assert {:error, unsafe_workbench_execution} =
             Tasks.execute_task_action(
               task["ref"],
               "use_workbench",
               Map.merge(session_attrs, %{
                 "tool_name" => "write_file",
                 "arguments" => %{"path" => "blocked.txt", "content" => "blocked"}
               }),
               workspace: workspace
             )

    assert unsafe_workbench_execution["status"] == "error"
    assert unsafe_workbench_execution["reason"] == "unsafe_nested_effect_scope:workspace_durable"
  end

  test "stdio and cli execute task tools through the action layer" do
    %{home: home, workspace: workspace} = tmp_env()
    Config.bootstrap(home: home)
    Workspace.init(workspace)
    opts = [home: home, workspace: workspace]

    assert {:ok, task} =
             Tasks.create(%{"title" => "Executable bridge action flow"}, opts)

    assert %{"ok" => true, "result" => bridge_execution} =
             Bridge.Stdio.handle_request(
               %{
                 "method" => "tasks/execute_tool",
                 "params" => %{
                   "ref" => task["ref"],
                   "tool_name" => "add_label",
                   "arguments" => %{"name" => "bridge-action"}
                 }
               },
               opts
             )

    assert bridge_execution["status"] == "ok"

    assert [%{"name" => "bridge-action"}] =
             get_in(bridge_execution, ["result", "labels"])

    list_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "actions",
                 "list",
                 "--home",
                 home,
                 "--workspace",
                 workspace
               ]) == 0
      end)

    assert list_output =~ "Actions:"
    assert list_output =~ "add_comment"

    execute_output =
      capture_io(fn ->
        assert HoltWorks.CLI.main([
                 "tasks",
                 "tool",
                 "execute",
                 "--home",
                 home,
                 "--workspace",
                 workspace,
                 task["ref"],
                 "add_comment",
                 "--content",
                 "via cli action"
               ]) == 0
      end)

    assert execute_output =~ "Action execution:"
    assert execute_output =~ "Status: ok"

    assert {:ok, updated_task} = Tasks.get(task["ref"], opts)
    assert Enum.any?(updated_task["comments"], &(&1["body"] == "via cli action"))
  end

  defp tmp_env do
    base = Path.join(System.tmp_dir!(), "holtworks-test-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    workspace = Path.join(base, "workspace")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(base) end)

    %{home: home, workspace: workspace}
  end

  defp assert_event_types(actual_events, expected_events) do
    actual = MapSet.new(actual_events)
    missing = Enum.reject(expected_events, &MapSet.member?(actual, &1))
    assert missing == []
  end

  defp flatten_agent_event_tree(nil), do: []

  defp flatten_agent_event_tree(node) when is_map(node) do
    [node | Enum.flat_map(node["children"] || [], &flatten_agent_event_tree/1)]
  end

  defp graph_node(graph, node_key) do
    Enum.find(graph["nodes"] || [], &(&1["node_key"] == node_key))
  end

  defp blocker_codes(graph) do
    graph
    |> Map.get("mission_control", %{})
    |> Map.get("blockers", [])
    |> Enum.map(& &1["code"])
  end

  defp work_graph_blocker_codes(graph) do
    graph
    |> Map.get("completion_gate", %{})
    |> Map.get("blockers", [])
    |> Enum.map(& &1["code"])
  end

  defp evidence_gap_codes(report) do
    report
    |> Map.get("evidence_evaluation", %{})
    |> Map.get("missing_requirements", [])
    |> Enum.map(& &1["code"])
  end

  defp mark_agent_run_stale(workspace, task_id, work_id, agent_run_id) do
    stale_at =
      DateTime.utc_now()
      |> DateTime.add(-900, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    tasks =
      workspace
      |> Tasks.tasks_path()
      |> JSON.read([])
      |> Enum.map(fn task ->
        if task["id"] == task_id do
          task
          |> Map.put("status", "in_progress")
          |> Map.update("agent_work", [], fn work_items ->
            Enum.map(work_items, fn work ->
              if work["id"] == work_id do
                work
                |> Map.put("status", "running")
                |> Map.put("started_at", stale_at)
                |> Map.delete("completed_at")
              else
                work
              end
            end)
          end)
        else
          task
        end
      end)

    JSON.write(Tasks.tasks_path(workspace), tasks)

    runs =
      workspace
      |> Tasks.agent_runs_path()
      |> JSON.read([])
      |> Enum.map(fn run ->
        if run["id"] == agent_run_id do
          run
          |> Map.put("status", "running")
          |> Map.put("lifecycle_state", "running")
          |> Map.put("runtime_status", "running")
          |> Map.put("objective_status", "in_progress")
          |> Map.put("inserted_at", stale_at)
          |> Map.put("queued_at", stale_at)
          |> Map.put("started_at", stale_at)
          |> Map.put("heartbeat_at", stale_at)
          |> Map.put("last_event_at", stale_at)
          |> Map.put("last_effective_work_at", stale_at)
          |> Map.delete("completed_at")
        else
          run
        end
      end)

    JSON.write(Tasks.agent_runs_path(workspace), runs)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
