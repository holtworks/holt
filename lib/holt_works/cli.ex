defmodule HoltWorks.CLI do
  @moduledoc """
  Command-line interface for the HoltWorks executable.
  """

  alias HoltWorks.{
    AgentRuntime,
    Approvals,
    Config,
    Memory,
    Models,
    Paths,
    Runtime,
    Skills,
    Tasks,
    Workspace
  }

  alias HoltWorks.Runtime.Runs

  def main(args) when is_list(args) do
    case args do
      [] ->
        help()

      ["help"] ->
        help()

      ["--help"] ->
        help()

      ["-h"] ->
        help()

      ["version"] ->
        IO.puts("HoltWorks #{HoltWorks.version()}")
        0

      ["--version"] ->
        IO.puts(HoltWorks.version())
        0

      ["doctor"] ->
        doctor([])

      ["doctor" | rest] ->
        doctor(rest)

      ["onboard"] ->
        onboard([])

      ["onboard" | rest] ->
        onboard(rest)

      ["run" | rest] ->
        run(rest)

      ["resume" | rest] ->
        resume(rest)

      ["chat" | rest] ->
        chat(rest)

      ["status" | rest] ->
        status(rest)

      ["logs" | rest] ->
        logs(rest)

      ["tasks"] ->
        tasks_help()

      ["tasks", "help"] ->
        tasks_help()

      ["tasks", "create" | rest] ->
        tasks_create(rest)

      ["tasks", "list" | rest] ->
        tasks_list(rest)

      ["tasks", "show" | rest] ->
        tasks_show(rest)

      ["tasks", "update" | rest] ->
        tasks_update(rest)

      ["tasks", "comment", "delete" | rest] ->
        tasks_comment_delete(rest)

      ["tasks", "comment" | rest] ->
        tasks_comment(rest)

      ["tasks", "label", "add" | rest] ->
        tasks_label_add(rest)

      ["tasks", "label", "remove" | rest] ->
        tasks_label_remove(rest)

      ["tasks", "link", "add" | rest] ->
        tasks_link_add(rest)

      ["tasks", "link", "remove" | rest] ->
        tasks_link_remove(rest)

      ["tasks", "spec" | rest] ->
        tasks_spec(rest)

      ["tasks", "specs", "list" | rest] ->
        tasks_specs_list(rest)

      ["tasks", "specs", "get" | rest] ->
        tasks_specs_get(rest)

      ["tasks", "run" | rest] ->
        tasks_run(rest)

      ["tasks", "continue" | rest] ->
        tasks_continue(rest)

      ["tasks", "verify" | rest] ->
        tasks_verify(rest)

      ["tasks", "graph" | rest] ->
        tasks_graph(rest)

      ["tasks", "evidence-contract" | rest] ->
        tasks_evidence_contract(rest)

      ["tasks", "verifier", "route" | rest] ->
        tasks_verifier_route(rest)

      ["tasks", "verifier", "contract" | rest] ->
        tasks_verifier_contract(rest)

      ["tasks", "verifier", "assign" | rest] ->
        tasks_verifier_assign(rest)

      ["tasks", "verifier", "dispatch" | rest] ->
        tasks_verifier_dispatch(rest)

      ["tasks", "verifier", "calibrate" | rest] ->
        tasks_verifier_calibrate(rest)

      ["tasks", "work-graph" | rest] ->
        tasks_work_graph(rest)

      ["tasks", "work-graph-gate" | rest] ->
        tasks_work_graph_gate(rest)

      ["tasks", "work-graph-budget" | rest] ->
        tasks_work_graph_budget(rest)

      ["tasks", "work-graph-schedule" | rest] ->
        tasks_work_graph_schedule(rest)

      ["tasks", "dispatch-plan" | rest] ->
        tasks_dispatch_plan(rest)

      ["tasks", "team-plan" | rest] ->
        tasks_team_plan(rest)

      ["tasks", "child-contract" | rest] ->
        tasks_child_contract(rest)

      ["tasks", "tool-session" | rest] ->
        tasks_tool_session(rest)

      ["tasks", "tool", "execute" | rest] ->
        tasks_tool_execute(rest)

      ["tasks", "tool", "multi-execute" | rest] ->
        tasks_tool_multi_execute(rest)

      ["tasks", "tool", "route" | rest] ->
        tasks_tool_route(rest)

      ["tasks", "action-contract" | rest] ->
        tasks_action_contract(rest)

      ["tasks", "plan-contract" | rest] ->
        tasks_plan_contract(rest)

      ["tasks", "plan-gate" | rest] ->
        tasks_plan_gate(rest)

      ["tasks", "preflight" | rest] ->
        tasks_preflight(rest)

      ["tasks", "consequence-gate" | rest] ->
        tasks_consequence_gate(rest)

      ["tasks", "action-envelope" | rest] ->
        tasks_action_envelope(rest)

      ["tasks", "approval-request" | rest] ->
        tasks_approval_request(rest)

      ["tasks", "approval-resolve" | rest] ->
        tasks_approval_resolve(rest)

      ["tasks", "evidence-ledger" | rest] ->
        tasks_evidence_ledger(rest)

      ["tasks", "memory-artifact" | rest] ->
        tasks_memory_artifact(rest)

      ["tasks", "memory-context" | rest] ->
        tasks_memory_context(rest)

      ["tasks", "context-budget" | rest] ->
        tasks_context_budget(rest)

      ["tasks", "continuation-packet" | rest] ->
        tasks_continuation_packet(rest)

      ["tasks", "capability-registry" | rest] ->
        tasks_capability_registry(rest)

      ["tasks", "capability-contract" | rest] ->
        tasks_capability_contract(rest)

      ["tasks", "capability-route" | rest] ->
        tasks_capability_route(rest)

      ["tasks", "generic-plan" | rest] ->
        tasks_generic_plan(rest)

      ["tasks", "runtime", "doctor" | rest] ->
        tasks_runtime_doctor(rest)

      ["tasks", "runtime", "tools" | rest] ->
        tasks_runtime_tools(rest)

      ["tasks", "runtime", "provider" | rest] ->
        tasks_runtime_provider(rest)

      ["tasks", "runtime", "safety" | rest] ->
        tasks_runtime_safety(rest)

      ["tasks", "runtime", "context-budget" | rest] ->
        tasks_runtime_context_budget(rest)

      ["tasks", "runtime", "recovery" | rest] ->
        tasks_runtime_recovery(rest)

      ["tasks", "runtime", "debug" | rest] ->
        tasks_runtime_debug(rest)

      ["tasks", "runtime", "learn" | rest] ->
        tasks_runtime_learn(rest)

      ["tasks", "runtime", "sanitize" | rest] ->
        tasks_runtime_sanitize(rest)

      ["tasks", "process", "started" | rest] ->
        tasks_process_started(rest)

      ["tasks", "process", "terminal" | rest] ->
        tasks_process_terminal(rest)

      ["tasks", "runs", "events" | rest] ->
        tasks_run_events(rest)

      ["tasks", "runs", "replay" | rest] ->
        tasks_run_replay(rest)

      ["tasks", "runs", "record" | rest] ->
        tasks_run_record(rest)

      ["tasks", "runs", "tool-event" | rest] ->
        tasks_run_tool_event(rest)

      ["tasks", "watchdog" | rest] ->
        tasks_watchdog(rest)

      ["actions"] ->
        actions_help()

      ["actions", "help"] ->
        actions_help()

      ["actions", "list" | rest] ->
        actions_list(rest)

      ["actions", "get" | rest] ->
        actions_get(rest)

      ["actions", "run" | rest] ->
        actions_run(rest)

      ["agents"] ->
        agents_help()

      ["agents", "help"] ->
        agents_help()

      ["agents", "list" | rest] ->
        agents_list(rest)

      ["agents", "create" | rest] ->
        agents_create(rest)

      ["agents", "show" | rest] ->
        agents_show(rest)

      ["agents", "update" | rest] ->
        agents_update(rest)

      ["agents", "suspend" | rest] ->
        agents_suspend(rest)

      ["agents", "resume" | rest] ->
        agents_resume(rest)

      ["agents", "archive" | rest] ->
        agents_archive(rest)

      ["agents", "cards" | rest] ->
        agents_cards(rest)

      ["agents", "skills" | rest] ->
        agents_skills(rest)

      ["approve" | rest] ->
        approve(rest)

      ["skills", "list" | rest] ->
        skills_list(rest)

      ["memory", "search" | rest] ->
        memory_search(rest)

      ["llm", "test" | rest] ->
        llm_test(rest)

      ["bridge", "stdio" | rest] ->
        bridge_stdio(rest)

      [unknown | _rest] ->
        IO.puts(:stderr, "Unknown command: #{unknown}")
        IO.puts(:stderr, "Run `holtworks help` for usage.")
        64
    end
  end

  def main(_args) do
    IO.puts(:stderr, "Invalid arguments")
    64
  end

  defp help do
    IO.write("""
    HoltWorks #{HoltWorks.version()}

    Usage:
      holtworks help                         Show this help
      holtworks version                      Print the installed version
      holtworks doctor [--json]              Check the local runtime
      holtworks onboard [--yes]              Create local config and workspace
      holtworks run [--yes] "task"           Run a local agent task
      holtworks resume [--yes] [run_id]      Resume a prior run objective
      holtworks chat                         Start a one-turn local chat
      holtworks status [--json]              Show gateway and latest run status
      holtworks logs                         Print latest run events
      holtworks tasks list                   List local tasks
      holtworks tasks create "title"         Create a local task
      holtworks tasks tool execute HW-01 add_comment --content "..."
      holtworks tasks run HW-01 [--yes]      Run agent work for a task
      holtworks tasks verify HW-01 --check name:passed
      holtworks actions list                 List executable action definitions
      holtworks agents list                  List local agent profiles
      holtworks agents create agent_id       Create a local agent profile
      holtworks approve [approval_id]        List or approve pending approvals
      holtworks skills list                  List available skills
      holtworks memory search "query"        Search local memory
      holtworks llm test [provider]          Test a configured model provider
      holtworks bridge stdio                 Serve JSON-lines local bridge

    """)

    0
  end

  defp doctor(args) do
    {opts, _rest} = parse_opts(args)
    HoltWorks.Env.load(opts)
    home = Paths.home(opts)
    root = Paths.workspace_root(opts)
    Config.bootstrap(home: home)
    provider = Models.default_provider(home)

    checks = %{
      "version" => HoltWorks.version(),
      "standalone_binary" => standalone?(),
      "home" => home,
      "home_exists" => File.dir?(home),
      "workspace" => root,
      "workspace_initialized" => Workspace.initialized?(root),
      "provider" => provider,
      "provider_valid" => inspect(Models.validate(provider)),
      "gateway" => HoltWorks.Gateway.status(home: home)
    }

    if opts[:json] do
      IO.puts(Jason.encode!(checks, pretty: true))
    else
      IO.puts("HoltWorks runtime: ok")
      IO.puts("Version: #{checks["version"]}")
      IO.puts("Home: #{checks["home"]}")
      IO.puts("Workspace: #{checks["workspace"]}")
      IO.puts("Workspace initialized: #{checks["workspace_initialized"]}")
      IO.puts("Provider: #{provider["id"] || provider["type"]}")
      IO.puts("Gateway: #{checks["gateway"]["status"]}")
    end

    0
  end

  defp onboard(args) do
    {opts, _rest} = parse_opts(args)
    HoltWorks.Env.load(opts)
    home = Paths.home(opts)
    root = Paths.workspace_root(opts)
    bootstrap = Config.bootstrap(home: home)

    providers =
      bootstrap.providers
      |> maybe_update_provider(opts)

    Config.save_providers(home, providers)
    workspace = Workspace.init(root)

    IO.puts("HoltWorks is ready.")
    IO.puts("Home: #{home}")
    IO.puts("Workspace: #{workspace.dir}")
    IO.puts("Created: #{format_created(workspace.created)}")
    IO.puts("Provider: #{providers["default_provider"]}")
    IO.puts("Provider check: #{inspect(Models.validate(Models.default_provider(home)))}")
    IO.puts("Gateway: #{HoltWorks.Gateway.status(home: home)["status"]}")
    IO.puts("")
    IO.puts("Next:")
    IO.puts("  holtworks run \"inspect this folder and create a short implementation plan\"")
    0
  end

  defp run(args) do
    {opts, rest} = parse_opts(args)
    objective = rest |> Enum.join(" ") |> String.trim()

    if objective == "" do
      IO.puts(:stderr, "Usage: holtworks run [--yes] \"task\"")
      64
    else
      maybe_read_key_from_stdin(opts)

      case Runtime.run(objective, with_approval(opts)) do
        {:ok, %{run: run, output: output, artifact: artifact}} ->
          IO.puts(output)
          IO.puts("")
          IO.puts("Run: #{run["id"]}")
          IO.puts("Status: #{run["status"]}")
          if artifact, do: IO.puts("Artifact: #{artifact["path"]}")
          0

        {:error, %{run: run, reason: reason}} ->
          IO.puts(:stderr, "Run failed: #{inspect(reason)}")
          IO.puts(:stderr, "Run: #{run["id"]}")
          1

        {:error, reason} ->
          IO.puts(:stderr, "Run failed: #{inspect(reason)}")
          1
      end
    end
  end

  defp resume(args) do
    {opts, rest} = parse_opts(args)
    run_ref = List.first(rest) || "latest"
    maybe_read_key_from_stdin(opts)

    case Runtime.resume(run_ref, with_approval(opts)) do
      {:ok, %{run: run, output: output, artifact: artifact}} ->
        IO.puts(output)
        IO.puts("")
        IO.puts("Run: #{run["id"]}")
        IO.puts("Resumed from: #{run["resumed_from"]}")
        IO.puts("Status: #{run["status"]}")
        if artifact, do: IO.puts("Artifact: #{artifact["path"]}")
        0

      {:error, :run_not_found} ->
        IO.puts(:stderr, "No matching run found.")
        1

      {:error, reason} ->
        IO.puts(:stderr, "Resume failed: #{inspect(reason)}")
        1
    end
  end

  defp chat(args) do
    {opts, _rest} = parse_opts(args)
    input = IO.gets("holtworks> ")

    case String.trim(to_string(input)) do
      "" -> 0
      objective -> run(["--workspace", Paths.workspace_root(opts), objective])
    end
  end

  defp status(args) do
    {opts, _rest} = parse_opts(args)
    status = Runtime.status(opts)

    if opts[:json] do
      IO.puts(Jason.encode!(status, pretty: true))
    else
      IO.puts("Workspace: #{status["workspace"] || status.workspace}")

      IO.puts(
        "Workspace initialized: #{status["workspace_initialized"] || status.workspace_initialized}"
      )

      IO.puts(
        "Gateway: #{get_in(status, ["gateway", "status"]) || get_in(status, [:gateway, "status"])}"
      )

      latest = status["latest_run"] || status.latest_run

      if latest do
        IO.puts("Latest run: #{latest["id"]} #{latest["status"]}")
      else
        IO.puts("Latest run: none")
      end
    end

    0
  end

  defp logs(args) do
    {opts, _rest} = parse_opts(args)
    root = Paths.workspace_root(opts)

    case Runs.latest(root) do
      nil ->
        IO.puts("No runs found.")

      %{"run_dir" => run_dir} ->
        run_dir
        |> Runs.events()
        |> Enum.each(&IO.puts(Jason.encode!(&1)))
    end

    0
  end

  defp tasks_help do
    IO.write("""
    HoltWorks tasks

    Usage:
      holtworks tasks list [--status todo|in_progress|waiting|done|all] [--json]
      holtworks tasks create [--description text] [--priority high] "title"
      holtworks tasks show HW-01 [--json]
      holtworks tasks update HW-01 [--status in_progress] [--priority high]
      holtworks tasks comment HW-01 "comment body"
      holtworks tasks comment delete HW-01 comment_id
      holtworks tasks label add HW-01 "frontend" [--color "#2563eb"]
      holtworks tasks link add HW-01 HW-02 --type depends_on
      holtworks tasks spec HW-01 --kind decision --title "Decision" --content "..."
      holtworks tasks specs list HW-01
      holtworks tasks specs get spec_id [--task HW-01]
      holtworks tasks run HW-01 [--agent agent_id] [--max-agents-per-event 2] [--message text] [--auto-continue --max-continuation-depth 2] [--yes]
      holtworks tasks continue HW-01 [--message text] [--auto-continue] [--yes]
      holtworks tasks verify HW-01 --check tests:passed --summary "ready"
      holtworks tasks graph create HW-01 [--type workflow|deep_concept] [--json]
      holtworks tasks graph list HW-01 [--json]
      holtworks tasks graph show graph_id [--json]
      holtworks tasks graph complete graph_id node_key [--summary text] [--json]
      holtworks tasks evidence-contract HW-01 [--json]
      holtworks tasks verifier route HW-01 [--graph-id task_graph_id] [--json]
      holtworks tasks verifier contract HW-01 [--json]
      holtworks tasks verifier assign HW-01 [--graph-id task_graph_id] [--json]
      holtworks tasks verifier dispatch HW-01 [--graph-id task_graph_id] [--json]
      holtworks tasks verifier calibrate HW-01 --verifier-agent-id agent --later-outcome matched [--json]
      holtworks tasks work-graph HW-01 [--graph-id task_graph_id] [--json]
      holtworks tasks work-graph-gate HW-01 [--graph-id task_graph_id] [--json]
      holtworks tasks work-graph-budget HW-01 [--group-token-budget 64000] [--json]
      holtworks tasks work-graph-schedule HW-01 [--graph-id task_graph_id] [--json]
      holtworks tasks dispatch-plan HW-01 [--max-agents-per-event 2] [--json]
      holtworks tasks team-plan HW-01 [--task-complexity implementation] [--json]
      holtworks tasks child-contract HW-01 [tool_name] [--role worker] [--json]
      holtworks tasks tool-session HW-01 [--disabled-tool tool] [--json]
      holtworks tasks tool route HW-01 tool_name [--json]
      holtworks tasks tool execute HW-01 tool_name [--content "..."] [--json]
      holtworks tasks tool execute HW-01 set_priority --priority high [--json]
      holtworks tasks tool execute HW-01 todo_write --content "..." [--json]
      holtworks tasks tool execute HW-01 manage_connection --json
      holtworks tasks tool execute HW-01 use_workbench --tool read_file --path README.md [--json]
      holtworks tasks tool multi-execute HW-01 --content '[{"tool_name":"get_task"}]' [--json]
      holtworks tasks action-contract HW-01 tool_name [--json]
      holtworks tasks plan-contract HW-01 [--json]
      holtworks tasks plan-gate HW-01 tool_name [--json]
      holtworks tasks preflight HW-01 tool_name [--json]
      holtworks tasks consequence-gate HW-01 tool_name [--json]
      holtworks tasks action-envelope HW-01 tool_name [--json]
      holtworks tasks approval-request HW-01 tool_name [--json]
      holtworks tasks approval-resolve approval_request_id --decision approved [--json]
      holtworks tasks evidence-ledger HW-01 tool_name [--result-status ok] [--json]
      holtworks tasks memory-artifact HW-01 --kind handoff --content "..." [--json]
      holtworks tasks memory-context HW-01 [--json]
      holtworks tasks context-budget HW-01 [--estimated-input-tokens 4000] [--json]
      holtworks tasks continuation-packet HW-01 [--previous-run-id run_id] [--json]
      holtworks tasks capability-registry tool_name [--json]
      holtworks tasks capability-contract HW-01 [tool_name] [--role worker] [--json]
      holtworks tasks capability-route HW-01 [tool_name] [--role worker] [--json]
      holtworks tasks generic-plan HW-01 [--json]
      holtworks tasks runtime doctor [--json]
      holtworks tasks runtime tools [--tool tool_name] [--json]
      holtworks tasks runtime provider [model_id] [--provider openai] [--json]
      holtworks tasks runtime safety [--task-complexity implementation] [--json]
      holtworks tasks runtime context-budget [--model model_id] [--estimated-input-tokens 4000] [--json]
      holtworks tasks runtime recovery tool_name [--effect-scope task_durable] [--json]
      holtworks tasks runtime debug [--json]
      holtworks tasks runtime learn [--json]
      holtworks tasks runtime sanitize --content "..." [--json]
      holtworks tasks process started agent_run_id [--managed-process-id id] [--json]
      holtworks tasks process terminal agent_run_id [--status exited] [--exit-code 0] [--json]
      holtworks tasks runs events agent_run_id [--json]
      holtworks tasks runs replay agent_id agent_run_id [--json]
      holtworks tasks runs record agent_run_id --kind agent.event --message "..." [--json]
      holtworks tasks runs tool-event agent_run_id tool_name [--tool-call-id call_id] [--result-status ok] [--json]
      holtworks tasks watchdog [--stale-after-seconds 300] [--json] [--yes]

    """)

    0
  end

  defp actions_help do
    IO.write("""
    HoltWorks actions

    Usage:
      holtworks actions list [--json]
      holtworks actions get action_name [--json]
      holtworks actions run action_name [--task HW-01] [--content "..."] [--json] [--yes]
      holtworks actions run create_task "title" [--priority high] [--json]

    """)

    0
  end

  defp agents_help do
    IO.write("""
    HoltWorks agents

    Usage:
      holtworks agents list [--status active] [--json]
      holtworks agents create agent_id [--name "Builder"] [--handle builder] [--role worker] [--skill planning] [--json]
      holtworks agents show agent_id [--json]
      holtworks agents update agent_id [--name "Builder"] [--skill planning] [--json]
      holtworks agents suspend agent_id [--reason code] [--json]
      holtworks agents resume agent_id [--json]
      holtworks agents archive agent_id [--json]
      holtworks agents cards [--json]
      holtworks agents skills agent_id [--json]

    """)

    0
  end

  defp agents_list(args) do
    {opts, _rest} = parse_opts(args)
    status = opts[:status]

    agents =
      Tasks.agents(opts)
      |> filter_cli_status(status)

    if opts[:json],
      do: IO.puts(Jason.encode!(agents, pretty: true)),
      else: print_agent_profiles(agents)

    0
  end

  defp agents_create(args) do
    {opts, rest} = parse_opts(args)
    agent_id = List.first(rest) || opts[:agent]

    if agent_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks agents create agent_id")
      64
    else
      attrs = agent_cli_attrs(opts) |> Map.put("id", agent_id)

      case Tasks.create_agent(attrs, opts) do
        {:ok, agent} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(agent, pretty: true)),
            else: print_agent_profile(agent)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not create agent: #{inspect(reason)}")
          1
      end
    end
  end

  defp agents_show(args) do
    {opts, rest} = parse_opts(args)
    agent_id = List.first(rest) || opts[:agent]

    if agent_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks agents show agent_id")
      64
    else
      case Tasks.get_agent(agent_id, opts) do
        {:ok, agent} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(agent, pretty: true)),
            else: print_agent_profile(agent)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not find agent: #{inspect(reason)}")
          1
      end
    end
  end

  defp agents_update(args) do
    {opts, rest} = parse_opts(args)
    agent_id = List.first(rest) || opts[:agent]

    if agent_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks agents update agent_id")
      64
    else
      case Tasks.update_agent(agent_id, agent_cli_attrs(opts), opts) do
        {:ok, agent} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(agent, pretty: true)),
            else: print_agent_profile(agent)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not update agent: #{inspect(reason)}")
          1
      end
    end
  end

  defp agents_suspend(args) do
    lifecycle_agent(args, "suspend", &Tasks.suspend_agent/3)
  end

  defp agents_resume(args) do
    lifecycle_agent(args, "resume", &Tasks.resume_agent/3)
  end

  defp agents_archive(args) do
    lifecycle_agent(args, "archive", &Tasks.archive_agent/3)
  end

  defp agents_cards(args) do
    {opts, _rest} = parse_opts(args)
    cards = Tasks.agent_cards(opts)

    if opts[:json],
      do: IO.puts(Jason.encode!(cards, pretty: true)),
      else: Enum.each(cards, &print_agent_card/1)

    0
  end

  defp agents_skills(args) do
    {opts, rest} = parse_opts(args)
    agent_id = List.first(rest) || opts[:agent]

    if agent_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks agents skills agent_id")
      64
    else
      case Tasks.agent_skills(agent_id, opts) do
        {:ok, skills} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(skills, pretty: true)),
            else: print_agent_skills(agent_id, skills)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not list agent skills: #{inspect(reason)}")
          1
      end
    end
  end

  defp lifecycle_agent(args, action, fun) do
    {opts, rest} = parse_opts(args)
    agent_id = List.first(rest) || opts[:agent]

    if agent_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks agents #{action} agent_id")
      64
    else
      attrs = %{"reason" => opts[:reason] || opts[:reason_code]} |> reject_empty_cli_map()

      case fun.(agent_id, attrs, opts) do
        {:ok, agent} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(agent, pretty: true)),
            else: print_agent_profile(agent)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not #{action} agent: #{inspect(reason)}")
          1
      end
    end
  end

  defp tasks_runtime_doctor(args) do
    {opts, _rest} = parse_opts(args)
    result = AgentRuntime.doctor(runtime_cli_attrs(opts))

    if opts[:json],
      do: IO.puts(Jason.encode!(result, pretty: true)),
      else: print_runtime_doctor(result)

    0
  end

  defp tasks_runtime_tools(args) do
    {opts, _rest} = parse_opts(args)
    result = AgentRuntime.tool_availability(runtime_cli_attrs(opts))

    if opts[:json],
      do: IO.puts(Jason.encode!(result, pretty: true)),
      else: print_tool_availability(result)

    0
  end

  defp tasks_runtime_provider(args) do
    {opts, rest} = parse_opts(args)
    model_id = List.first(rest) || opts[:model] || "local-planner"
    result = AgentRuntime.provider_profile(model_id, runtime_cli_attrs(opts))

    if opts[:json],
      do: IO.puts(Jason.encode!(result, pretty: true)),
      else: print_provider_profile(result)

    0
  end

  defp tasks_runtime_safety(args) do
    {opts, _rest} = parse_opts(args)
    result = AgentRuntime.safety_policy(runtime_cli_attrs(opts))

    if opts[:json],
      do: IO.puts(Jason.encode!(result, pretty: true)),
      else: print_safety_policy(result)

    0
  end

  defp tasks_runtime_context_budget(args) do
    {opts, _rest} = parse_opts(args)
    result = AgentRuntime.context_budget(runtime_context_budget_attrs(opts))

    if opts[:json],
      do: IO.puts(Jason.encode!(result, pretty: true)),
      else: print_runtime_context_budget(result)

    0
  end

  defp tasks_runtime_recovery(args) do
    {opts, rest} = parse_opts(args)
    tool_name = List.first(rest) || opts[:tool] || "unknown"
    result = AgentRuntime.recovery_contract(runtime_recovery_attrs(opts, tool_name))

    if opts[:json],
      do: IO.puts(Jason.encode!(result, pretty: true)),
      else: print_recovery_contract(result)

    0
  end

  defp tasks_runtime_debug(args) do
    {opts, _rest} = parse_opts(args)
    result = AgentRuntime.run_debugger(%{})

    if opts[:json],
      do: IO.puts(Jason.encode!(result, pretty: true)),
      else: print_run_debugger(result)

    0
  end

  defp tasks_runtime_learn(args) do
    {opts, _rest} = parse_opts(args)
    result = AgentRuntime.meta_learning_snapshot(%{})

    if opts[:json],
      do: IO.puts(Jason.encode!(result, pretty: true)),
      else: print_meta_learning_snapshot(result)

    0
  end

  defp tasks_runtime_sanitize(args) do
    {opts, rest} = parse_opts(args)
    content = opts[:content] || rest |> Enum.join(" ") |> String.trim()
    result = AgentRuntime.format_local_model_result(content)

    if opts[:json],
      do: IO.puts(Jason.encode!(%{"content" => result}, pretty: true)),
      else: IO.puts(result)

    0
  end

  defp tasks_process_started(args) do
    {opts, rest} = parse_opts(args)
    agent_run_id = List.first(rest) || opts[:agent_run_id]

    if agent_run_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks tasks process started agent_run_id")
      64
    else
      payload = process_payload_attrs(opts, "running")

      case Tasks.record_process_started(payload, %{"agent_run_id" => agent_run_id}, opts) do
        {:ok, result} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(result, pretty: true)),
            else: print_process_event_result(result)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not record process start: #{inspect(reason)}")
          1
      end
    end
  end

  defp tasks_process_terminal(args) do
    {opts, rest} = parse_opts(args)
    agent_run_id = List.first(rest) || opts[:agent_run_id]

    if agent_run_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks tasks process terminal agent_run_id")
      64
    else
      payload = process_payload_attrs(opts, "exited")

      case Tasks.notify_process_terminal(payload, %{"agent_run_id" => agent_run_id}, opts) do
        {:ok, result} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(result, pretty: true)),
            else: print_process_event_result(result)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not record process terminal event: #{inspect(reason)}")
          1
      end
    end
  end

  defp tasks_run_events(args) do
    {opts, rest} = parse_opts(args)
    agent_run_id = List.first(rest) || opts[:agent_run_id]

    if agent_run_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks tasks runs events agent_run_id")
      64
    else
      case Tasks.agent_run_event_log(agent_run_id, opts) do
        {:ok, events} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(events, pretty: true)),
            else: print_agent_run_events(events)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not list agent run events: #{inspect(reason)}")
          1
      end
    end
  end

  defp tasks_run_replay(args) do
    {opts, rest} = parse_opts(args)
    agent_id = List.first(rest) || opts[:agent]
    agent_run_id = Enum.at(rest, 1) || opts[:agent_run_id]

    if agent_id in [nil, ""] or agent_run_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks tasks runs replay agent_id agent_run_id")
      64
    else
      case Tasks.agent_run_replay(agent_id, agent_run_id, opts) do
        {:ok, replay} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(replay, pretty: true)),
            else: print_agent_run_replay(replay)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not build agent run replay: #{inspect(reason)}")
          1
      end
    end
  end

  defp tasks_run_record(args) do
    {opts, rest} = parse_opts(args)
    agent_run_id = List.first(rest) || opts[:agent_run_id]

    if agent_run_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks tasks runs record agent_run_id --kind kind")
      64
    else
      attrs =
        %{}
        |> maybe_put("kind", opts[:kind] || opts[:type] || opts[:event_kind])
        |> maybe_put("message", opts[:message] || opts[:content])
        |> maybe_put("idempotency_key", opts[:idempotency_key])
        |> reject_empty_cli_map()

      case Tasks.record_agent_run_event(agent_run_id, attrs, opts) do
        {:ok, _run, event} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(event, pretty: true)),
            else: print_agent_run_event(event)

          0

        {:duplicate, _run, event} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(event, pretty: true)),
            else: print_agent_run_event(event)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not record agent run event: #{inspect(reason)}")
          1
      end
    end
  end

  defp tasks_run_tool_event(args) do
    {opts, rest} = parse_opts(args)
    agent_run_id = List.first(rest) || opts[:agent_run_id]
    tool_name = Enum.at(rest, 1) || opts[:tool]

    if agent_run_id in [nil, ""] or tool_name in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks tasks runs tool-event agent_run_id tool_name")
      64
    else
      attrs =
        %{
          "tool_name" => tool_name,
          "tool_call_id" => opts[:tool_call_id],
          "result_status" => opts[:result_status],
          "result_preview" => opts[:result_preview],
          "message" => opts[:message],
          "idempotency_key" => opts[:idempotency_key]
        }
        |> reject_empty_cli_map()

      case Tasks.record_agent_run_tool_event(agent_run_id, attrs, opts) do
        {:ok, _run, event} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(event, pretty: true)),
            else: print_agent_run_event(event)

          0

        {:duplicate, _run, event} ->
          if opts[:json],
            do: IO.puts(Jason.encode!(event, pretty: true)),
            else: print_agent_run_event(event)

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not record tool event: #{inspect(reason)}")
          1
      end
    end
  end

  defp tasks_create(args) do
    {opts, rest} = parse_opts(args)

    attrs =
      opts
      |> task_attrs()
      |> Map.put("title", rest |> Enum.join(" ") |> String.trim())

    case Tasks.create(attrs, opts) do
      {:ok, task} ->
        if opts[:json] do
          IO.puts(Jason.encode!(task, pretty: true))
        else
          IO.puts("Created #{task["ref"]}: #{task["title"]}")
          IO.puts("Status: #{task["status"]}")
          IO.puts("Priority: #{task["priority"]}")
        end

        0

      {:error, reason} ->
        IO.puts(:stderr, "Could not create task: #{inspect(reason)}")
        64
    end
  end

  defp tasks_list(args) do
    {opts, _rest} = parse_opts(args)
    tasks = Tasks.list(opts)

    if opts[:json] do
      IO.puts(Jason.encode!(tasks, pretty: true))
    else
      if tasks == [] do
        IO.puts("No tasks found.")
      else
        Enum.each(tasks, fn task ->
          IO.puts("#{task["ref"]} #{task["status"]} #{task["priority"]} #{task["title"]}")
        end)
      end
    end

    0
  end

  defp tasks_show(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        case Tasks.get(ref, opts) do
          {:ok, task} ->
            if opts[:json] do
              IO.puts(Jason.encode!(task, pretty: true))
            else
              print_task(task)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Task not found: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks show HW-01")
        64
    end
  end

  defp tasks_update(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = task_attrs(opts)

        if map_size(attrs) == 0 do
          IO.puts(:stderr, "Usage: holtworks tasks update HW-01 [--status done]")
          64
        else
          case Tasks.update(ref, attrs, opts) do
            {:ok, task} ->
              if opts[:json],
                do: IO.puts(Jason.encode!(task, pretty: true)),
                else: print_task(task)

              0

            {:error, reason} ->
              IO.puts(:stderr, "Could not update task: #{inspect(reason)}")
              1
          end
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks update HW-01 [--status done]")
        64
    end
  end

  defp tasks_comment(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | body_parts] ->
        body = body_parts |> Enum.join(" ") |> String.trim()

        case Tasks.add_comment(ref, body, opts) do
          {:ok, task} ->
            IO.puts("Comment added to #{task["ref"]}.")
            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not add comment: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks comment HW-01 \"comment body\"")
        64
    end
  end

  defp tasks_comment_delete(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, comment_id | _tail] ->
        case Tasks.delete_comment(ref, comment_id, opts) do
          {:ok, task} ->
            IO.puts("Comment deleted from #{task["ref"]}.")
            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not delete comment: #{inspect(reason)}")
            1
        end

      _ ->
        IO.puts(:stderr, "Usage: holtworks tasks comment delete HW-01 comment_id")
        64
    end
  end

  defp tasks_label_add(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | name_parts] ->
        attrs =
          %{
            "name" => name_parts |> Enum.join(" ") |> String.trim(),
            "color" => opts[:color]
          }

        case Tasks.add_label(ref, attrs, opts) do
          {:ok, task} ->
            IO.puts("Labels on #{task["ref"]}: #{format_labels(task["labels"] || [])}")
            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not add label: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks label add HW-01 \"label\"")
        64
    end
  end

  defp tasks_label_remove(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | name_parts] ->
        name = name_parts |> Enum.join(" ") |> String.trim()

        case Tasks.remove_label(ref, name, opts) do
          {:ok, task} ->
            IO.puts("Labels on #{task["ref"]}: #{format_labels(task["labels"] || [])}")
            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not remove label: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks label remove HW-01 \"label\"")
        64
    end
  end

  defp tasks_link_add(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, target | _tail] ->
        case Tasks.add_link(ref, target, opts[:type] || "relates_to", opts) do
          {:ok, task} ->
            IO.puts("Links on #{task["ref"]}: #{length(task["links"] || [])}")
            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not add link: #{inspect(reason)}")
            1
        end

      _ ->
        IO.puts(:stderr, "Usage: holtworks tasks link add HW-01 HW-02 --type depends_on")
        64
    end
  end

  defp tasks_link_remove(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, link_id | _tail] ->
        case Tasks.remove_link(ref, link_id, opts) do
          {:ok, task} ->
            IO.puts("Links on #{task["ref"]}: #{length(task["links"] || [])}")
            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not remove link: #{inspect(reason)}")
            1
        end

      _ ->
        IO.puts(:stderr, "Usage: holtworks tasks link remove HW-01 link_id")
        64
    end
  end

  defp tasks_spec(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | content_parts] ->
        content =
          opts[:content] ||
            content_parts |> Enum.join(" ") |> String.trim()

        attrs =
          %{}
          |> maybe_put("kind", opts[:kind])
          |> maybe_put("title", opts[:title])
          |> maybe_put("content", content)

        case Tasks.save_spec(ref, attrs, opts) do
          {:ok, spec} ->
            IO.puts("Saved #{spec["kind"]} spec #{spec["id"]} for #{spec["task_ref"]}.")
            IO.puts("Path: #{spec["path"]}")
            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not save spec: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks spec HW-01 --kind decision --content \"...\"")
        64
    end
  end

  defp tasks_specs_list(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        list_opts =
          opts
          |> Keyword.put(:kind, opts[:kind] || "all")
          |> Keyword.put(:include_content, opts[:include_content] || false)
          |> Keyword.put(:content_limit, opts[:content_limit])

        case Tasks.list_specs(ref, list_opts) do
          {:ok, specs} ->
            if opts[:json] do
              IO.puts(Jason.encode!(specs, pretty: true))
            else
              Enum.each(specs, fn spec ->
                IO.puts("#{spec["id"]} #{spec["kind"]} #{spec["title"]}")
              end)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not list specs: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks specs list HW-01")
        64
    end
  end

  defp tasks_specs_get(args) do
    {opts, rest} = parse_opts(args)

    spec_id = opts[:spec_id] || List.first(rest)

    if spec_id in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks tasks specs get spec_id [--task HW-01]")
      64
    else
      spec_opts =
        opts
        |> Keyword.put(:task_ref, opts[:task])
        |> Keyword.put(:content_limit, opts[:content_limit])

      case Tasks.get_spec(spec_id, spec_opts) do
        {:ok, spec} ->
          if opts[:json] do
            IO.puts(Jason.encode!(spec, pretty: true))
          else
            IO.puts("#{spec["id"]} #{spec["kind"]} #{spec["title"]}")
            IO.puts("")
            IO.puts(spec["content"] || "")
          end

          0

        {:error, reason} ->
          IO.puts(:stderr, "Could not read spec: #{inspect(reason)}")
          1
      end
    end
  end

  defp tasks_run(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | message_parts] ->
        maybe_read_key_from_stdin(opts)

        message =
          opts[:message] ||
            message_parts |> Enum.join(" ") |> String.trim()

        attrs =
          %{}
          |> maybe_put("message", message)
          |> maybe_put("mode", opts[:mode])
          |> maybe_put("agent_ids", Keyword.get_values(opts, :agent))
          |> maybe_put("max_agents_per_event", opts[:max_agents_per_event])
          |> maybe_put("auto_continue", opts[:auto_continue])
          |> maybe_put("max_continuation_depth", opts[:max_continuation_depth])
          |> maybe_put("retry_on_failure", opts[:retry_on_failure])

        case Tasks.start_agent_work(ref, attrs, with_approval(opts)) do
          {:ok, %{task: task, run: run, output: output, artifact: artifact}} ->
            IO.puts(output)
            IO.puts("")
            IO.puts("Task: #{task["ref"]}")
            IO.puts("Task status: #{task["status"]}")
            IO.puts("Run: #{run["id"]}")
            IO.puts("Run status: #{run["status"]}")
            if artifact, do: IO.puts("Artifact: #{artifact["path"]}")
            0

          {:error, %{task: task, run: run, reason: reason}} ->
            IO.puts(:stderr, "Task run failed: #{inspect(reason)}")
            IO.puts(:stderr, "Task: #{task["ref"]}")
            IO.puts(:stderr, "Run: #{run["id"]}")
            1

          {:error, reason} ->
            IO.puts(:stderr, "Task run failed: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks run HW-01 [--yes]")
        64
    end
  end

  defp tasks_continue(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | message_parts] ->
        maybe_read_key_from_stdin(opts)

        message =
          opts[:message] ||
            message_parts |> Enum.join(" ") |> String.trim()

        attrs =
          %{}
          |> maybe_put("message", message)
          |> maybe_put("mode", opts[:mode])
          |> maybe_put("agent_ids", Keyword.get_values(opts, :agent))
          |> maybe_put("max_agents_per_event", opts[:max_agents_per_event])
          |> maybe_put("auto_continue", opts[:auto_continue])
          |> maybe_put("max_continuation_depth", opts[:max_continuation_depth])
          |> maybe_put("retry_on_failure", opts[:retry_on_failure])

        case Tasks.continue_agent_work(ref, attrs, with_approval(opts)) do
          {:ok, %{task: task, run: run, output: output, artifact: artifact, agent_work: work}} ->
            IO.puts(output)
            IO.puts("")
            IO.puts("Task: #{task["ref"]}")
            IO.puts("Task status: #{task["status"]}")
            IO.puts("Continuation: #{work["iteration"]}")
            IO.puts("Resumed from: #{run["resumed_from"]}")
            IO.puts("Run: #{run["id"]}")
            IO.puts("Run status: #{run["status"]}")
            if artifact, do: IO.puts("Artifact: #{artifact["path"]}")
            0

          {:error, %{task: task, run: run, reason: reason}} ->
            IO.puts(:stderr, "Task continuation failed: #{inspect(reason)}")
            IO.puts(:stderr, "Task: #{task["ref"]}")
            IO.puts(:stderr, "Run: #{run["id"]}")
            1

          {:error, reason} ->
            IO.puts(:stderr, "Task continuation failed: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks continue HW-01 [--yes]")
        64
    end
  end

  defp tasks_verify(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        case parse_cli_checks(Keyword.get_values(opts, :check)) do
          {:ok, checks} ->
            attrs =
              %{
                "summary" => opts[:summary],
                "checks" => checks
              }

            case Tasks.route_verification(ref, attrs, opts) do
              {:ok, %{task: task, spec: spec}} ->
                IO.puts("Verification routed: #{task["ref"]} -> #{task["status"]}")
                IO.puts("Report: #{spec["path"]}")
                0

              {:error, reason} ->
                IO.puts(:stderr, "Could not route verification: #{inspect(reason)}")
                1
            end

          {:error, reason} ->
            IO.puts(:stderr, "Invalid check: #{inspect(reason)}")
            64
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks verify HW-01 --check tests:passed")
        64
    end
  end

  defp tasks_graph(args) do
    case args do
      ["create" | rest] ->
        tasks_graph_create(rest)

      ["list" | rest] ->
        tasks_graph_list(rest)

      ["show" | rest] ->
        tasks_graph_show(rest)

      ["complete" | rest] ->
        tasks_graph_complete(rest)

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks graph create|list|show|complete")
        64
    end
  end

  defp tasks_graph_create(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs =
          %{}
          |> maybe_put("graph_type", opts[:type])
          |> maybe_put("title", opts[:title])

        case Tasks.create_task_graph(ref, attrs, opts) do
          {:ok, graph} ->
            if opts[:json] do
              IO.puts(Jason.encode!(graph, pretty: true))
            else
              print_task_graph(graph)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not create task graph: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks graph create HW-01")
        64
    end
  end

  defp tasks_graph_list(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        case Tasks.task_graphs(ref, opts) do
          {:ok, graphs} ->
            if opts[:json] do
              IO.puts(Jason.encode!(graphs, pretty: true))
            else
              Enum.each(graphs, &print_task_graph_summary/1)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not list task graphs: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks graph list HW-01")
        64
    end
  end

  defp tasks_graph_show(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [graph_id | _tail] ->
        case Tasks.get_task_graph(graph_id, opts) do
          {:ok, graph} ->
            if opts[:json] do
              IO.puts(Jason.encode!(graph, pretty: true))
            else
              print_task_graph(graph)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not show task graph: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks graph show graph_id")
        64
    end
  end

  defp tasks_graph_complete(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [graph_id, node_ref | _tail] ->
        attrs =
          %{}
          |> maybe_put("summary", opts[:summary])
          |> maybe_put("output", opts[:content])

        case Tasks.complete_task_graph_node(graph_id, node_ref, attrs, opts) do
          {:ok, graph} ->
            if opts[:json] do
              IO.puts(Jason.encode!(graph, pretty: true))
            else
              print_task_graph(graph)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not complete task graph node: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks graph complete graph_id node_key")
        64
    end
  end

  defp tasks_evidence_contract(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        case Tasks.evidence_contract(ref, %{}, opts) do
          {:ok, contract} ->
            if opts[:json] do
              IO.puts(Jason.encode!(contract, pretty: true))
            else
              print_evidence_contract(contract)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build evidence contract: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks evidence-contract HW-01")
        64
    end
  end

  defp tasks_verifier_route(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs =
          %{}
          |> maybe_put("graph_id", opts[:graph_id])

        case Tasks.plan_verifier_route(ref, attrs, opts) do
          {:ok, result} ->
            if opts[:json] do
              IO.puts(Jason.encode!(result, pretty: true))
            else
              print_verifier_route(result[:route] || result["route"])
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not plan verifier route: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks verifier route HW-01")
        64
    end
  end

  defp tasks_verifier_contract(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = verification_cli_attrs(opts)

        case Tasks.verification_contract(ref, attrs, opts) do
          {:ok, contract} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(contract, pretty: true)),
              else: print_verification_contract(contract)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build verification contract: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks verifier contract HW-01")
        64
    end
  end

  defp tasks_verifier_assign(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = verification_cli_attrs(opts)

        case Tasks.verifier_assignment(ref, attrs, opts) do
          {:ok, assignment} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(assignment, pretty: true)),
              else: print_verifier_assignment(assignment)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not assign verifier: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks verifier assign HW-01")
        64
    end
  end

  defp tasks_verifier_dispatch(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = verification_cli_attrs(opts)

        case Tasks.verifier_dispatch(ref, attrs, opts) do
          {:ok, dispatch} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(dispatch, pretty: true)),
              else: print_verifier_dispatch(dispatch)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not dispatch verifier: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks verifier dispatch HW-01")
        64
    end
  end

  defp tasks_verifier_calibrate(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = verification_cli_attrs(opts)

        case Tasks.verifier_calibration(ref, attrs, opts) do
          {:ok, calibration} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(calibration, pretty: true)),
              else: print_verifier_calibration(calibration)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not calibrate verifier: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks verifier calibrate HW-01")
        64
    end
  end

  defp tasks_work_graph(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = orchestration_cli_attrs(opts)

        case Tasks.work_graph(ref, attrs, opts) do
          {:ok, graph} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(graph, pretty: true)),
              else: print_work_graph(graph)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build work graph: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks work-graph HW-01")
        64
    end
  end

  defp tasks_work_graph_gate(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = orchestration_cli_attrs(opts)

        case Tasks.work_graph_gate(ref, attrs, opts) do
          {:ok, gate} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(gate, pretty: true)),
              else: print_work_graph_gate(gate)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not evaluate work graph gate: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks work-graph-gate HW-01")
        64
    end
  end

  defp tasks_work_graph_budget(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = orchestration_cli_attrs(opts)

        case Tasks.work_graph_budget(ref, attrs, opts) do
          {:ok, budget} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(budget, pretty: true)),
              else: print_work_graph_budget(budget)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build work graph budget: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks work-graph-budget HW-01")
        64
    end
  end

  defp tasks_work_graph_schedule(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = orchestration_cli_attrs(opts)

        case Tasks.work_graph_schedule(ref, attrs, opts) do
          {:ok, schedule} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(schedule, pretty: true)),
              else: print_work_graph_schedule(schedule)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not schedule work graph: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks work-graph-schedule HW-01")
        64
    end
  end

  defp tasks_dispatch_plan(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = orchestration_cli_attrs(opts)

        case Tasks.agent_dispatch_plan(ref, attrs, opts) do
          {:ok, plan} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(plan, pretty: true)),
              else: print_dispatch_plan(plan)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build dispatch plan: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks dispatch-plan HW-01")
        64
    end
  end

  defp tasks_team_plan(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = orchestration_cli_attrs(opts)

        case Tasks.team_orchestration(ref, attrs, opts) do
          {:ok, plan} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(plan, pretty: true)),
              else: print_team_plan(plan)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build team plan: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks team-plan HW-01")
        64
    end
  end

  defp tasks_child_contract(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | tail] ->
        attrs =
          opts
          |> orchestration_cli_attrs()
          |> maybe_put("tool_name", opts[:tool] || List.first(tail))
          |> maybe_put("role", opts[:role])
          |> maybe_put("arguments", child_contract_arguments(opts, tail))

        case Tasks.child_agent_contract(ref, attrs, opts) do
          {:ok, contract} ->
            if opts[:json],
              do: IO.puts(Jason.encode!(contract, pretty: true)),
              else: print_child_agent_contract(contract)

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build child-agent contract: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks child-contract HW-01 [tool_name]")
        64
    end
  end

  defp tasks_tool_session(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = task_tool_attrs(opts)

        case Tasks.task_tool_session(ref, attrs, opts) do
          {:ok, session} ->
            if opts[:json] do
              IO.puts(Jason.encode!(session, pretty: true))
            else
              print_task_tool_session(session)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build task tool session: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks tool-session HW-01")
        64
    end
  end

  defp tasks_tool_route(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | _tail] ->
        attrs =
          opts
          |> task_tool_attrs()
          |> Map.put("tool_name", tool_name)

        case Tasks.route_task_tool(ref, attrs, opts) do
          {:ok, route} ->
            if opts[:json] do
              IO.puts(Jason.encode!(route, pretty: true))
            else
              print_task_tool_route(route)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not route task tool: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks tool route HW-01 tool_name")
        64
    end
  end

  defp tasks_tool_execute(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | tail] ->
        action_opts = with_approval(opts)
        attrs = action_cli_attrs(tool_name, opts, tail)

        case Tasks.execute_task_action(ref, tool_name, attrs, action_opts) do
          {:ok, execution} ->
            if opts[:json] do
              IO.puts(Jason.encode!(execution, pretty: true))
            else
              print_action_execution(execution)
            end

            0

          {:error, %{} = execution} ->
            if opts[:json] do
              IO.puts(Jason.encode!(execution, pretty: true))
            else
              print_action_execution(execution)
            end

            1

          {:error, reason} ->
            IO.puts(:stderr, "Could not execute task tool: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks tool execute HW-01 tool_name")
        64
    end
  end

  defp tasks_tool_multi_execute(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        with {:ok, calls} <- decode_action_calls(opts[:content]) do
          case Tasks.execute_task_actions(ref, calls, with_approval(opts)) do
            {:ok, executions} ->
              if opts[:json] do
                IO.puts(Jason.encode!(executions, pretty: true))
              else
                Enum.each(executions, &print_action_execution/1)
              end

              0

            {:error, executions} when is_list(executions) ->
              if opts[:json] do
                IO.puts(Jason.encode!(executions, pretty: true))
              else
                Enum.each(executions, &print_action_execution/1)
              end

              1

            {:error, reason} ->
              IO.puts(:stderr, "Could not execute task tools: #{inspect(reason)}")
              1
          end
        else
          {:error, reason} ->
            IO.puts(:stderr, "Could not parse action calls: #{inspect(reason)}")
            64
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks tool multi-execute HW-01 --content '[...]'")
        64
    end
  end

  defp tasks_action_contract(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | _tail] ->
        attrs =
          opts
          |> task_tool_attrs()
          |> Map.put("tool_name", tool_name)

        case Tasks.action_contract(ref, attrs, opts) do
          {:ok, contract} ->
            if opts[:json] do
              IO.puts(Jason.encode!(contract, pretty: true))
            else
              print_action_contract(contract)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build action contract: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks action-contract HW-01 tool_name")
        64
    end
  end

  defp tasks_plan_contract(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = task_tool_attrs(opts)

        case Tasks.plan_contract(ref, attrs, opts) do
          {:ok, contract} ->
            if opts[:json] do
              IO.puts(Jason.encode!(contract, pretty: true))
            else
              print_plan_contract(contract)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build plan contract: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks plan-contract HW-01")
        64
    end
  end

  defp tasks_plan_gate(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | _tail] ->
        attrs =
          opts
          |> task_tool_attrs()
          |> Map.put("tool_name", tool_name)

        case Tasks.plan_gate(ref, attrs, opts) do
          {:ok, gate} ->
            if opts[:json] do
              IO.puts(Jason.encode!(gate, pretty: true))
            else
              print_plan_gate(gate)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not evaluate plan gate: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks plan-gate HW-01 tool_name")
        64
    end
  end

  defp tasks_preflight(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | _tail] ->
        attrs =
          opts
          |> task_tool_attrs()
          |> Map.put("tool_name", tool_name)
          |> maybe_put("approval_status", opts[:approval_status])

        case Tasks.action_preflight(ref, attrs, opts) do
          {:ok, preflight} ->
            if opts[:json] do
              IO.puts(Jason.encode!(preflight, pretty: true))
            else
              print_action_preflight(preflight)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not evaluate action preflight: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks preflight HW-01 tool_name")
        64
    end
  end

  defp tasks_consequence_gate(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | _tail] ->
        attrs =
          opts
          |> task_tool_attrs()
          |> Map.put("tool_name", tool_name)
          |> maybe_put("approval_status", opts[:approval_status])

        case Tasks.consequence_gate(ref, attrs, opts) do
          {:ok, gate} ->
            if opts[:json] do
              IO.puts(Jason.encode!(gate, pretty: true))
            else
              print_consequence_gate(gate)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not evaluate consequence gate: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks consequence-gate HW-01 tool_name")
        64
    end
  end

  defp tasks_action_envelope(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | _tail] ->
        attrs =
          opts
          |> task_tool_attrs()
          |> Map.put("tool_name", tool_name)
          |> maybe_put("approval_status", opts[:approval_status])

        case Tasks.action_runtime_envelope(ref, attrs, opts) do
          {:ok, envelope} ->
            if opts[:json] do
              IO.puts(Jason.encode!(envelope, pretty: true))
            else
              print_action_runtime_envelope(envelope)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build action runtime envelope: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks action-envelope HW-01 tool_name")
        64
    end
  end

  defp tasks_approval_request(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | _tail] ->
        attrs =
          opts
          |> task_tool_attrs()
          |> Map.put("tool_name", tool_name)
          |> maybe_put("force_approval_request", opts[:force_approval_request])

        case Tasks.action_approval_request(ref, attrs, opts) do
          {:ok, request} ->
            if opts[:json] do
              IO.puts(Jason.encode!(request, pretty: true))
            else
              print_action_approval_request(request)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build approval request: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks approval-request HW-01 tool_name")
        64
    end
  end

  defp tasks_approval_resolve(args) do
    {opts, rest} = parse_opts(args)

    case {rest, opts[:decision]} do
      {[request_id | _tail], decision} when decision not in [nil, ""] ->
        attrs =
          %{}
          |> maybe_put("decision", decision)
          |> maybe_put("decided_by", opts[:decided_by])
          |> maybe_put("reason_code", opts[:reason_code])

        case Tasks.resolve_action_approval_request(request_id, attrs, opts) do
          {:ok, request} ->
            if opts[:json] do
              IO.puts(Jason.encode!(request, pretty: true))
            else
              print_action_approval_request(request)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not resolve approval request: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(
          :stderr,
          "Usage: holtworks tasks approval-resolve approval_request_id --decision approved"
        )

        64
    end
  end

  defp tasks_evidence_ledger(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref, tool_name | _tail] ->
        attrs =
          opts
          |> task_tool_attrs()
          |> Map.put("tool_name", tool_name)
          |> maybe_put("artifact_ref", opts[:artifact_ref])
          |> maybe_put("result_status", opts[:result_status])
          |> maybe_put("result_preview", opts[:result_preview])

        case Tasks.action_evidence_ledger(ref, attrs, opts) do
          {:ok, ledger} ->
            if opts[:json] do
              IO.puts(Jason.encode!(ledger, pretty: true))
            else
              print_action_evidence_ledger(ledger)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build evidence ledger: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks evidence-ledger HW-01 tool_name")
        64
    end
  end

  defp tasks_memory_artifact(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs =
          %{}
          |> maybe_put("kind", opts[:kind])
          |> maybe_put("title", opts[:title])
          |> maybe_put("content", opts[:content])
          |> maybe_put("source", opts[:source])
          |> maybe_put("agent_run_id", opts[:agent_run_id])
          |> maybe_put("agent_work_id", opts[:agent_work_id])
          |> maybe_put("tool_name", opts[:tool])

        case Tasks.record_task_memory_artifact(ref, attrs, opts) do
          {:ok, artifact} ->
            if opts[:json] do
              IO.puts(Jason.encode!(artifact, pretty: true))
            else
              print_task_memory_artifact(artifact)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not record task memory artifact: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks memory-artifact HW-01 --content text")
        64
    end
  end

  defp tasks_memory_context(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = context_budget_attrs(opts)

        case Tasks.task_memory_context(ref, attrs, opts) do
          {:ok, packet} ->
            if opts[:json] do
              IO.puts(Jason.encode!(packet, pretty: true))
            else
              print_task_memory_context(packet)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build task memory context: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks memory-context HW-01")
        64
    end
  end

  defp tasks_context_budget(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = context_budget_attrs(opts)

        case Tasks.context_budget(ref, attrs, opts) do
          {:ok, budget} ->
            if opts[:json] do
              IO.puts(Jason.encode!(budget, pretty: true))
            else
              print_context_budget(budget)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build context budget: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks context-budget HW-01")
        64
    end
  end

  defp tasks_continuation_packet(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs =
          context_budget_attrs(opts)
          |> maybe_put("previous_run_id", opts[:previous_run_id])
          |> maybe_put("previous_agent_run_id", opts[:previous_agent_run_id])
          |> maybe_put("previous_agent_work_id", opts[:previous_agent_work_id])
          |> maybe_put("agent_work_id", opts[:agent_work_id])
          |> maybe_put("agent_id", opts[:agent])

        case Tasks.continuation_packet(ref, attrs, opts) do
          {:ok, packet} ->
            if opts[:json] do
              IO.puts(Jason.encode!(packet, pretty: true))
            else
              print_continuation_packet(packet)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build continuation packet: #{inspect(reason)}")
            1
        end

      [] ->
        IO.puts(:stderr, "Usage: holtworks tasks continuation-packet HW-01")
        64
    end
  end

  defp tasks_capability_registry(args) do
    {opts, rest} = parse_opts(args)
    tool_name = opts[:tool] || List.first(rest)

    if tool_name in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks tasks capability-registry tool_name")
      64
    else
      {:ok, entry} = Tasks.capability_registry(tool_name, %{"tool_name" => tool_name})

      if opts[:json] do
        IO.puts(Jason.encode!(entry, pretty: true))
      else
        print_capability_registry_entry(entry)
      end

      0
    end
  end

  defp tasks_capability_contract(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | tail] ->
        attrs = capability_cli_attrs(opts, List.first(tail))

        case Tasks.capability_contract(ref, attrs, opts) do
          {:ok, contract} ->
            if opts[:json] do
              IO.puts(Jason.encode!(contract, pretty: true))
            else
              print_capability_contract(contract)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build capability contract: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks capability-contract HW-01 [tool_name]")
        64
    end
  end

  defp tasks_capability_route(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | tail] ->
        attrs = capability_cli_attrs(opts, List.first(tail))

        case Tasks.capability_route(ref, attrs, opts) do
          {:ok, route} ->
            if opts[:json] do
              IO.puts(Jason.encode!(route, pretty: true))
            else
              print_capability_route(route)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not route capability: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks capability-route HW-01 [tool_name]")
        64
    end
  end

  defp tasks_generic_plan(args) do
    {opts, rest} = parse_opts(args)

    case rest do
      [ref | _tail] ->
        attrs = capability_cli_attrs(opts, nil)

        case Tasks.generic_plan(ref, attrs, opts) do
          {:ok, plan} ->
            if opts[:json] do
              IO.puts(Jason.encode!(plan, pretty: true))
            else
              print_generic_plan(plan)
            end

            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not build generic plan: #{inspect(reason)}")
            1
        end

      _other ->
        IO.puts(:stderr, "Usage: holtworks tasks generic-plan HW-01")
        64
    end
  end

  defp tasks_watchdog(args) do
    {opts, _rest} = parse_opts(args)
    maybe_read_key_from_stdin(opts)

    scan_opts =
      with_approval(opts)
      |> maybe_put_opt(:limit, opts[:limit])
      |> maybe_put_opt(:stale_after_seconds, opts[:stale_after_seconds])
      |> maybe_put_opt(:recovery_cooldown_seconds, opts[:recovery_cooldown_seconds])

    results = Tasks.watchdog_scan(scan_opts)

    if opts[:json] do
      IO.puts(Jason.encode!(results, pretty: true))
    else
      if results == [] do
        IO.puts("No agent runs need watchdog attention.")
      else
        Enum.each(results, fn result ->
          IO.puts(
            "#{result["task_ref"] || "task"} #{result["agent_id"] || "agent"} #{result["action"]}: #{result["reason"]}"
          )
        end)
      end
    end

    0
  end

  defp actions_list(args) do
    {opts, _rest} = parse_opts(args)
    actions = Tasks.action_definitions(opts)

    if opts[:json] do
      IO.puts(Jason.encode!(actions, pretty: true))
    else
      print_action_definitions(actions)
    end

    0
  end

  defp actions_get(args) do
    {opts, rest} = parse_opts(args)
    name = opts[:tool] || List.first(rest)

    if name in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks actions get action_name")
      64
    else
      case Tasks.get_action(name, opts) do
        nil ->
          IO.puts(:stderr, "Unknown action: #{name}")
          1

        action ->
          if opts[:json] do
            IO.puts(Jason.encode!(action, pretty: true))
          else
            print_action_definition(action)
          end

          0
      end
    end
  end

  defp actions_run(args) do
    {opts, rest} = parse_opts(args)
    name = opts[:tool] || List.first(rest)

    if name in [nil, ""] do
      IO.puts(:stderr, "Usage: holtworks actions run action_name [--task HW-01]")
      64
    else
      attrs =
        name
        |> action_cli_attrs(opts, Enum.drop(rest, 1))
        |> maybe_put("ref", opts[:task])

      case Tasks.execute_action(name, attrs, with_approval(opts)) do
        {:ok, execution} ->
          if opts[:json] do
            IO.puts(Jason.encode!(execution, pretty: true))
          else
            print_action_execution(execution)
          end

          0

        {:error, %{} = execution} ->
          if opts[:json] do
            IO.puts(Jason.encode!(execution, pretty: true))
          else
            print_action_execution(execution)
          end

          1

        {:error, reason} ->
          IO.puts(:stderr, "Could not execute action: #{inspect(reason)}")
          1
      end
    end
  end

  defp approve(args) do
    {opts, rest} = parse_opts(args)
    root = Paths.workspace_root(opts)

    case rest do
      [] ->
        pending = Approvals.pending(root)

        if pending == [] do
          IO.puts("No pending approvals.")
        else
          Enum.each(pending, fn record ->
            IO.puts("#{record["id"]} #{record["tool"]} #{record["risk"]}: #{record["reason"]}")
          end)
        end

        0

      [id] ->
        case Approvals.resolve(root, id, "approved") do
          {:ok, _record} ->
            IO.puts("Approved #{id}")
            0

          {:error, reason} ->
            IO.puts(:stderr, "Could not approve #{id}: #{inspect(reason)}")
            1
        end
    end
  end

  defp skills_list(args) do
    {opts, _rest} = parse_opts(args)

    opts
    |> Skills.list()
    |> Enum.each(fn skill ->
      IO.puts("#{skill.name} [#{skill.risk}] #{skill.description}")
      IO.puts("  #{skill.path}")
    end)

    0
  end

  defp memory_search(args) do
    {opts, rest} = parse_opts(args)
    query = Enum.join(rest, " ")

    query
    |> Memory.search(opts)
    |> Enum.each(fn entry ->
      IO.puts("#{entry["id"]} #{entry["kind"]}: #{entry["text"]}")
    end)

    0
  end

  defp bridge_stdio(args) do
    {opts, _rest} = parse_opts(args)
    HoltWorks.Bridge.Stdio.serve(with_approval(opts))
    0
  end

  defp llm_test(args) do
    {opts, rest} = parse_opts(args)
    HoltWorks.Env.load(opts)
    home = Paths.home(opts)
    Config.bootstrap(home: home)
    provider_id = List.first(rest) || "openrouter"

    provider =
      home
      |> Models.provider(provider_id)
      |> maybe_override_model(opts)
      |> maybe_shrink_smoke_response()

    maybe_read_key_from_stdin(opts, provider)

    case Models.validate(provider) do
      :ok ->
        run_llm_smoke(provider, opts)

      {:error, {:missing_env, env}} ->
        IO.puts(
          :stderr,
          "Missing #{env}. Export it before running the #{provider_id} smoke test."
        )

        78

      {:error, reason} ->
        IO.puts(:stderr, "Provider check failed: #{inspect(reason)}")
        1
    end
  end

  defp task_attrs(opts) do
    %{}
    |> maybe_put("title", opts[:title])
    |> maybe_put("description", opts[:description])
    |> maybe_put("status", opts[:status])
    |> maybe_put("priority", opts[:priority])
    |> maybe_put("estimate", opts[:estimate])
    |> maybe_put("kind", opts[:kind])
    |> maybe_put("parent_id", opts[:parent])
    |> maybe_put("due_date", opts[:due_date])
    |> maybe_put("scheduled_start_at", opts[:scheduled_start_at])
    |> maybe_put("assignees", Keyword.get_values(opts, :assignee))
    |> maybe_put("labels", Keyword.get_values(opts, :label))
  end

  defp task_tool_attrs(opts) do
    %{}
    |> maybe_put("agent_id", opts[:agent])
    |> maybe_put("graph_id", opts[:graph_id])
    |> maybe_put("enabled_toolkits", Keyword.get_values(opts, :enabled_toolkit))
    |> maybe_put("disabled_toolkits", Keyword.get_values(opts, :disabled_toolkit))
    |> maybe_put("disabled_tools", Keyword.get_values(opts, :disabled_tool))
    |> maybe_put("direct_tools", Keyword.get_values(opts, :direct_tool))
    |> maybe_put("allow_workspace_durable", opts[:allow_workspace_durable])
  end

  defp action_cli_attrs(tool_name, opts, positional_values) do
    content = opts[:content] || Enum.join(positional_values, " ")
    title = opts[:title] || if(positional_values == [], do: nil, else: content)

    opts
    |> task_tool_attrs()
    |> maybe_put("body", content)
    |> maybe_put("content", opts[:content])
    |> maybe_put("title", title)
    |> maybe_put("description", opts[:description])
    |> maybe_put("status", opts[:status])
    |> maybe_put("priority", opts[:priority])
    |> maybe_put("estimate", opts[:estimate])
    |> maybe_put("kind", opts[:kind])
    |> maybe_put("name", opts[:name])
    |> maybe_put("label", opts[:label])
    |> maybe_put("color", opts[:color])
    |> maybe_put("type", opts[:type])
    |> maybe_put("graph_id", opts[:graph_id])
    |> maybe_put("task_ref", opts[:task])
    |> maybe_put("spec_id", opts[:spec_id])
    |> maybe_put("message", opts[:message])
    |> maybe_put("mode", opts[:mode])
    |> maybe_put("summary", opts[:summary])
    |> maybe_put("agent_id", opts[:agent])
    |> maybe_put("limit", opts[:limit])
    |> maybe_put("tool_name", opts[:tool])
    |> maybe_put("tool_call_id", opts[:tool_call_id])
    |> maybe_put("result_status", opts[:result_status])
    |> maybe_put("result_preview", opts[:result_preview])
    |> maybe_put("artifact_ref", opts[:artifact_ref])
    |> maybe_put("previous_run_id", opts[:previous_run_id])
    |> maybe_put("agent_run_id", opts[:agent_run_id])
    |> maybe_put("estimated_input_tokens", opts[:estimated_input_tokens])
    |> maybe_put("path", opts[:path])
    |> maybe_put("query", opts[:query])
    |> maybe_put("command", opts[:command])
    |> maybe_put("url", opts[:url])
    |> maybe_put_todo_cli(tool_name, content)
  end

  defp maybe_put_todo_cli(attrs, "todo_write", content) do
    if Map.has_key?(attrs, "todos") or content in [nil, ""] do
      attrs
    else
      Map.put(attrs, "todos", todo_cli_items(content))
    end
  end

  defp maybe_put_todo_cli(attrs, _tool_name, _content), do: attrs

  defp todo_cli_items(content) do
    case Jason.decode(content) do
      {:ok, %{"todos" => todos}} when is_list(todos) ->
        todos

      {:ok, todos} when is_list(todos) ->
        todos

      _other ->
        [%{"content" => content, "status" => "pending"}]
    end
  end

  defp capability_cli_attrs(opts, positional_tool_name) do
    opts
    |> task_tool_attrs()
    |> maybe_put("tool_name", opts[:tool] || positional_tool_name)
    |> maybe_put("role", opts[:role])
    |> maybe_put("effect_scope", opts[:effect_scope])
    |> maybe_put("allowed_tools", Keyword.get_values(opts, :allowed_tool))
    |> maybe_put("required_tools", Keyword.get_values(opts, :required_tool))
    |> maybe_put("required_capabilities", Keyword.get_values(opts, :capability))
    |> maybe_put("input_artifact_kinds", Keyword.get_values(opts, :input_artifact))
    |> maybe_put("expected_output_artifact_kinds", Keyword.get_values(opts, :expected_output))
  end

  defp context_budget_attrs(opts) do
    %{}
    |> maybe_put("estimated_input_tokens", opts[:estimated_input_tokens])
    |> maybe_put("context_window", opts[:context_window])
    |> maybe_put("hard_limit_tokens", opts[:hard_limit_tokens])
    |> maybe_put("soft_limit_tokens", opts[:soft_limit_tokens])
    |> maybe_put("critical_limit_tokens", opts[:critical_limit_tokens])
    |> maybe_put("output_reserve_tokens", opts[:output_reserve_tokens])
    |> maybe_put("tool_reserve_tokens", opts[:tool_reserve_tokens])
  end

  defp runtime_cli_attrs(opts) do
    %{}
    |> maybe_put("provider", opts[:provider])
    |> maybe_put("model", opts[:model])
    |> maybe_put("base_url", opts[:base_url])
    |> maybe_put("api_key_env", opts[:api_key_env])
    |> maybe_put("context_window", opts[:context_window])
    |> maybe_put("output_reserve_tokens", opts[:output_reserve_tokens])
    |> maybe_put("tool_reserve_tokens", opts[:tool_reserve_tokens])
    |> maybe_put("task_complexity", opts[:task_complexity])
    |> maybe_put("max_attempts", opts[:max_attempts])
    |> maybe_put("max_continuation_depth", opts[:max_continuation_depth])
    |> maybe_put("workspace_status", opts[:workspace_status])
    |> maybe_put("network_status", opts[:network_status])
    |> maybe_put("network_enabled", opts[:network_enabled])
    |> maybe_put("approval_status", opts[:approval_status])
    |> maybe_put("tool_names", Keyword.get_values(opts, :tool))
  end

  defp agent_cli_attrs(opts) do
    %{}
    |> maybe_put("display_name", opts[:name] || opts[:title])
    |> maybe_put("description", opts[:description])
    |> maybe_put("agent_handle", opts[:handle])
    |> maybe_put("agent_ref", opts[:agent_ref])
    |> maybe_put("status", opts[:status])
    |> maybe_put("work_roles", agent_work_roles(opts))
    |> maybe_put("default_work_role", opts[:work_role] || opts[:role])
    |> maybe_put("skills", agent_skill_attrs(opts))
    |> maybe_put("model", opts[:model])
    |> maybe_put("provider", opts[:provider])
    |> maybe_put("instructions", opts[:instructions] || opts[:content])
    |> maybe_put("capabilities", Keyword.get_values(opts, :capability))
    |> reject_empty_cli_map()
  end

  defp agent_work_roles(opts) do
    Keyword.get_values(opts, :work_role) ++ Keyword.get_values(opts, :role)
  end

  defp agent_skill_attrs(opts) do
    opts
    |> Keyword.get_values(:skill)
    |> Enum.map(fn skill -> %{"name" => skill} end)
  end

  defp filter_cli_status(items, status) when status in [nil, "", "all"], do: items
  defp filter_cli_status(items, status), do: Enum.filter(items, &(&1["status"] == status))

  defp runtime_context_budget_attrs(opts) do
    provider =
      AgentRuntime.provider_profile(opts[:model] || "local-planner", runtime_cli_attrs(opts))

    %{
      "policy" =>
        %{}
        |> maybe_put("max_total_tokens", opts[:max_total_tokens])
        |> maybe_put("max_tool_calls", opts[:max_tool_calls])
        |> maybe_put("max_wall_clock_seconds", opts[:max_wall_clock_seconds]),
      "provider_profile" => provider
    }
    |> Map.merge(context_budget_attrs(opts))
    |> maybe_put("run_token_budget", opts[:token_budget])
  end

  defp runtime_recovery_attrs(opts, tool_name) do
    %{}
    |> maybe_put("tool_name", tool_name)
    |> maybe_put("effect_scope", opts[:effect_scope])
    |> maybe_put("risk_level", opts[:risk_level])
    |> maybe_put("target_refs", runtime_recovery_target_refs(opts))
  end

  defp runtime_recovery_target_refs(opts) do
    %{}
    |> maybe_put("task_ref", opts[:task])
    |> maybe_put("path", opts[:path])
    |> maybe_put("agent_run_id", opts[:agent_run_id])
    |> reject_empty_cli_map()
  end

  defp process_payload_attrs(opts, default_status) do
    %{}
    |> maybe_put("status", opts[:status] || default_status)
    |> maybe_put("managed_process_id", opts[:managed_process_id])
    |> maybe_put("process_id", opts[:process_id])
    |> maybe_put("sandbox_pid", opts[:sandbox_pid])
    |> maybe_put("status_path", opts[:status_path])
    |> maybe_put("exit_code", opts[:exit_code])
    |> maybe_put("wait_for_exit", opts[:wait_for_exit])
    |> maybe_put("notify_on_exit", opts[:notify_on_exit])
    |> maybe_put("log_tail", opts[:content])
    |> reject_empty_cli_map()
  end

  defp orchestration_cli_attrs(opts) do
    %{}
    |> maybe_put("graph_id", opts[:graph_id])
    |> maybe_put("group_token_budget", opts[:group_token_budget])
    |> maybe_put("token_budget", opts[:token_budget])
    |> maybe_put("max_total_tokens", opts[:max_total_tokens])
    |> maybe_put("max_concurrent_agents", opts[:max_concurrent_agents])
    |> maybe_put("max_agents_per_event", opts[:max_agents_per_event])
    |> maybe_put("task_complexity", opts[:task_complexity])
    |> maybe_put("event_kind", opts[:event_kind])
    |> maybe_put("request_id", opts[:request_id])
    |> maybe_put("source", opts[:source])
  end

  defp verification_cli_attrs(opts) do
    opts
    |> orchestration_cli_attrs()
    |> maybe_put("verification_required", opts[:verification_required])
    |> maybe_put("review_strategy", opts[:review_strategy])
    |> maybe_put("max_attempts", opts[:max_attempts])
    |> maybe_put("allow_ephemeral_verifier", opts[:allow_ephemeral_verifier])
    |> maybe_put("verifier_agent_id", opts[:verifier_agent_id])
    |> maybe_put("later_outcome", opts[:later_outcome])
    |> maybe_put("completion_decision", opts[:completion_decision])
    |> maybe_put("verification_status", opts[:verification_status])
    |> maybe_put("can_finish", opts[:can_finish])
    |> maybe_put("evaluation", verification_evaluation_attrs(opts))
  end

  defp verification_evaluation_attrs(opts) do
    %{}
    |> maybe_put("completion_decision", opts[:completion_decision])
    |> maybe_put("verification_status", opts[:verification_status])
    |> maybe_put("can_finish", opts[:can_finish])
    |> reject_empty_cli_map()
  end

  defp child_contract_arguments(opts, tail) do
    %{}
    |> maybe_put("work_role", opts[:role])
    |> maybe_put("target_agent_id", opts[:agent])
    |> maybe_put("target_skill", opts[:target_skill])
    |> maybe_put("allowed_tools", Keyword.get_values(opts, :allowed_tool))
    |> maybe_put("required_capabilities", Keyword.get_values(opts, :capability))
    |> maybe_put("expected_output_artifacts", Keyword.get_values(opts, :expected_output))
    |> maybe_put("instructions", child_contract_instructions(tail))
    |> reject_empty_cli_map()
  end

  defp child_contract_instructions([_tool_name | instruction_parts]) do
    instruction_parts
    |> Enum.join(" ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp child_contract_instructions(_tail), do: nil

  defp reject_empty_cli_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp print_task(task) do
    IO.puts("#{task["ref"]}: #{task["title"]}")
    IO.puts("Status: #{task["status"]}")
    IO.puts("Priority: #{task["priority"]}")
    IO.puts("Estimate: #{task["estimate"] || "none"}")
    IO.puts("Kind: #{task["kind"]}")
    IO.puts("Labels: #{format_labels(task["labels"] || [])}")
    IO.puts("Links: #{length(task["links"] || [])}")

    if task["description"] not in [nil, ""] do
      IO.puts("")
      IO.puts(task["description"])
    end

    IO.puts("")
    IO.puts("Comments: #{length(task["comments"] || [])}")
    IO.puts("Attachments: #{length(task["attachments"] || [])}")
    IO.puts("Agent work: #{length(task["agent_work"] || [])}")
  end

  defp print_task_graph_summary(graph) do
    gate = graph["mission_control"] || %{}

    IO.puts(
      "#{graph["id"]} #{graph["task_ref"]} #{graph["status"]} #{gate["status"] || "blocked"} #{graph["title"]}"
    )
  end

  defp print_task_graph(graph) do
    gate = graph["mission_control"] || %{}

    IO.puts("#{graph["id"]}: #{graph["title"]}")
    IO.puts("Task: #{graph["task_ref"]}")
    IO.puts("Type: #{graph["graph_type"]}")
    IO.puts("Status: #{graph["status"]}")
    IO.puts("Gate: #{gate["status"] || "blocked"}")
    IO.puts("Can finish: #{gate["can_finish"] == true}")
    IO.puts("")

    graph
    |> Map.get("nodes", [])
    |> Enum.each(fn node ->
      IO.puts("#{node["node_key"]} #{node["status"]} #{node["kind"]}: #{node["label"]}")
    end)

    blockers = gate["blockers"] || []

    if blockers != [] do
      IO.puts("")
      IO.puts("Blockers:")

      Enum.each(blockers, fn blocker ->
        IO.puts("- #{blocker["code"]}: #{blocker["message"]}")
      end)
    end
  end

  defp print_evidence_contract(contract) do
    IO.puts("Evidence contract: #{contract["profile"] || "generic"}")
    IO.puts("Required artifacts: #{format_words(contract["required_artifact_kinds"] || [])}")
    IO.puts("Allowed verifier tools: #{format_words(contract["allowed_verifier_tools"] || [])}")

    groups = contract["required_check_groups"] || []

    if groups == [] do
      IO.puts("Required check groups: none")
    else
      IO.puts("Required check groups:")

      Enum.each(groups, fn group ->
        IO.puts("- #{group["group_id"]}: #{format_words(group["any_of"] || [])}")
      end)
    end
  end

  defp print_verifier_route(route) when is_map(route) do
    IO.puts("Verifier route: #{route["route_id"]}")
    IO.puts("Status: #{route["status"]}")
    IO.puts("Task: #{route["task_ref"]}")
    IO.puts("Graph: #{route["graph_id"]}")
    IO.puts("Target agent: #{route["target_agent_id"]}")
    IO.puts("Allowed tools: #{format_words(route["allowed_tools"] || [])}")
  end

  defp print_verifier_route(_route), do: IO.puts("No verifier route.")

  defp print_verification_contract(contract) do
    IO.puts("Verification contract: #{contract["review_strategy"]}")
    IO.puts("Required: #{contract["required"] == true}")
    IO.puts("Gate tool: #{contract["gate_tool"]}")
    IO.puts("Pass policy: #{contract["pass_policy"]}")
    IO.puts("Max attempts: #{contract["max_attempts"]}")
  end

  defp print_verifier_assignment(assignment) do
    verifier = assignment["selected_verifier"] || %{}

    IO.puts("Verifier assignment: #{assignment["assignment_id"]}")
    IO.puts("Result: #{assignment["assignment_result"]}")
    IO.puts("Reason: #{assignment["reason"]}")
    IO.puts("Work product: #{assignment["work_product_ref"] || "unknown"}")
    IO.puts("Selected verifier: #{verifier["agent_id"] || verifier["name"] || "none"}")
    IO.puts("Eligible verifiers: #{length(assignment["eligible_verifiers"] || [])}")
  end

  defp print_verifier_dispatch(dispatch) do
    IO.puts("Verifier dispatch: #{dispatch["dispatch_id"]}")
    IO.puts("Status: #{dispatch["status"]}")
    IO.puts("Reason: #{dispatch["reason"] || "none"}")
    IO.puts("Route: #{dispatch["route_id"] || "none"}")
    IO.puts("Target agent: #{dispatch["target_agent_id"] || "ephemeral"}")
    IO.puts("Start source: #{get_in(dispatch, ["start_agent_work_params", "source"]) || "none"}")
  end

  defp print_verifier_calibration(calibration) do
    IO.puts("Verifier calibration: #{calibration["calibration_id"]}")
    IO.puts("Verifier: #{calibration["verifier_agent_id"] || "unknown"}")
    IO.puts("Verdict: #{calibration["verdict"]}")
    IO.puts("Later outcome: #{calibration["later_outcome"]}")
    IO.puts("Accuracy delta: #{calibration["accuracy_delta"]}")
    IO.puts("Future policy: #{calibration["recommended_future_assignment_policy"]}")
  end

  defp print_work_graph(graph) do
    gate = graph["completion_gate"] || %{}
    metrics = graph["metrics"] || %{}

    IO.puts("Work graph: #{graph["graph_id"]}")
    IO.puts("Task: #{graph["task_ref"] || graph["task_id"]}")
    IO.puts("Source: #{graph["source"]}")
    IO.puts("Status: #{graph["status"]}")
    IO.puts("Gate: #{gate["status"] || "blocked"}")
    IO.puts("Can finish: #{gate["can_finish"] == true}")
    IO.puts("Nodes: #{metrics["node_count"] || length(graph["nodes"] || [])}")
    IO.puts("")

    graph
    |> Map.get("nodes", [])
    |> Enum.each(fn node ->
      IO.puts("#{node["node_id"]} #{node["status"]} #{node["kind"]}: #{node["label"]}")
    end)

    print_work_graph_blockers(gate)
  end

  defp print_work_graph_gate(gate) do
    IO.puts("Work graph gate: #{gate["status"]}")
    IO.puts("Can finish: #{gate["can_finish"] == true}")
    IO.puts("Enforced: #{gate["enforced"] == true}")
    IO.puts("Verification satisfied: #{gate["verification_satisfied"] == true}")
    print_work_graph_blockers(gate)
  end

  defp print_work_graph_budget(budget) do
    allocation = budget["allocation"] || %{}

    IO.puts("Work graph budget: #{budget["budget_id"]}")
    IO.puts("Task: #{budget["task_ref"] || budget["task_id"]}")
    IO.puts("Total tokens: #{budget["max_total_tokens"]}")
    IO.puts("Max concurrent agents: #{budget["max_concurrent_agents"]}")
    IO.puts("Per active agent: #{allocation["per_active_agent_slice_tokens"]}")
    IO.puts("Verification reserve: #{allocation["verification_reserve_tokens"]}")
    IO.puts("Repair reserve: #{allocation["repair_reserve_tokens"]}")
  end

  defp print_work_graph_schedule(schedule) do
    IO.puts("Work graph schedule: #{schedule["schedule_id"]}")
    IO.puts("Status: #{schedule["status"]}")
    IO.puts("Ready: #{length(schedule["ready_nodes"] || [])}")
    IO.puts("Waiting: #{length(schedule["waiting_nodes"] || [])}")
    IO.puts("Blocked: #{length(schedule["blocked_nodes"] || [])}")
    IO.puts("Next actions: #{format_words(schedule["next_actions"] || [])}")

    schedule
    |> Map.get("ready_nodes", [])
    |> Enum.each(fn node ->
      IO.puts("#{node["node_id"]} ready: #{node["schedule_reason"]}")
    end)
  end

  defp print_dispatch_plan(plan) do
    IO.puts("Dispatch plan: #{plan["dispatch_id"]}")
    IO.puts("Decision: #{plan["dispatch_decision"] || plan["decision"]}")
    IO.puts("Candidates: #{plan["candidate_count"] || 0}")
    IO.puts("Selected: #{plan["selected_count"] || 0}")
    IO.puts("Suppressed: #{plan["suppressed_count"] || 0}")
    IO.puts("Budget: #{get_in(plan, ["group_budget", "budget_id"]) || "none"}")

    plan
    |> Map.get("selected_agents", [])
    |> Enum.each(fn agent ->
      IO.puts("#{agent["agent_id"]} selected: #{agent["context_partition"]}")
    end)
  end

  defp print_team_plan(plan) do
    IO.puts("Team plan: #{plan["mode"]}")
    IO.puts("Complexity: #{plan["task_complexity"]}")
    IO.puts("Max concurrent agents: #{plan["max_concurrent_agents"]}")

    plan
    |> Map.get("stages", [])
    |> Enum.each(fn stage ->
      IO.puts("#{stage["name"]} #{stage["role"]} required=#{stage["required"] == true}")
    end)
  end

  defp print_child_agent_contract(contract) do
    child = contract["child"] || %{}
    authority = contract["authority_boundary"] || %{}
    verification = contract["verification_contract"] || %{}

    IO.puts("Child-agent contract: #{contract["child_contract_id"]}")
    IO.puts("Status: #{contract["status"]}")
    IO.puts("Tool: #{contract["tool_name"]}")
    IO.puts("Role: #{child["work_role"] || "worker"}")

    IO.puts(
      "Target: #{child["target_agent_id"] || child["target_skill"] || child["child_ref"] || "unspecified"}"
    )

    IO.puts("May delegate further: #{authority["may_delegate_further"] == true}")
    IO.puts("Verifier required: #{verification["verifier_required"] == true}")
  end

  defp print_runtime_doctor(result) do
    IO.puts("Runtime doctor: #{result["status"]}")
    IO.puts("Tools checked: #{length(result["tools"] || [])}")
  end

  defp print_tool_availability(tools) do
    IO.puts("Tool availability: #{length(tools)}")

    Enum.each(tools, fn tool ->
      status = if tool["available"], do: "available", else: tool["unavailable_reason"]
      IO.puts("#{tool["name"]} #{status}")
    end)
  end

  defp print_provider_profile(profile) do
    IO.puts("Provider profile: #{profile["model"]}")
    IO.puts("Provider: #{profile["provider"]}")
    IO.puts("Runtime: #{profile["runtime_kind"]}")
    IO.puts("Context window: #{profile["context_window"]}")
  end

  defp print_safety_policy(policy) do
    IO.puts("Safety policy: #{policy["permission_mode"]}")
    IO.puts("Command policy: #{policy["command_policy"]}")
    IO.puts("Sandbox policy: #{policy["sandbox_policy"]}")
    IO.puts("Approval required for: #{format_words(policy["approval_required_for"] || [])}")
  end

  defp print_runtime_context_budget(budget) do
    governor = budget["governor"] || %{}
    compression = budget["compression"] || %{}

    IO.puts("Runtime context budget: #{governor["budget_state"]}")
    IO.puts("Action: #{governor["action"]}")
    IO.puts("Provider context window: #{budget["provider_context_window"]}")
    IO.puts("Compression: #{compression["strategy"]}")
  end

  defp print_recovery_contract(contract) do
    rollback = contract["rollback_plan"] || %{}

    IO.puts("Recovery contract: #{contract["recovery_id"]}")
    IO.puts("Tool: #{contract["tool_name"]}")
    IO.puts("Effect scope: #{contract["effect_scope"]}")
    IO.puts("Reversibility: #{contract["reversibility"]}")
    IO.puts("Rollback: #{rollback["strategy"]}")
    IO.puts("Recovery observation required: #{contract["requires_recovery_observation"] == true}")
  end

  defp print_run_debugger(debugger) do
    IO.puts("Run debugger: #{debugger["debugger_id"]}")
    IO.puts("Events: #{debugger["event_count"]}")
    IO.puts("Action envelopes: #{debugger["action_envelope_count"]}")
    IO.puts("Approval waits: #{debugger["approval_wait_count"]}")
    IO.puts("Repairs required: #{debugger["repair_required_count"]}")
    IO.puts("Prediction mismatches: #{debugger["prediction_mismatch_count"]}")
    IO.puts("Next actions: #{format_words(debugger["next_debug_actions"] || [])}")
  end

  defp print_meta_learning_snapshot(snapshot) do
    metrics = snapshot["metrics"] || %{}

    IO.puts("Meta-learning snapshot: #{snapshot["snapshot_id"]}")
    IO.puts("Prediction mismatches: #{metrics["prediction_mismatch_count"]}")
    IO.puts("Repairs required: #{metrics["repair_required_count"]}")
    IO.puts("Recommendations: #{length(snapshot["recommendations"] || [])}")
    IO.puts("Policy updates: #{length(snapshot["proposed_policy_updates"] || [])}")
  end

  defp print_process_event_result(result) do
    IO.puts("Process event: #{result["action"]}")
    IO.puts("Agent run: #{result["agent_run_id"] || "unknown"}")

    if result["event_kind"] not in [nil, ""] do
      IO.puts("Event: #{result["event_kind"]}")
    end

    if result["reason"] not in [nil, ""] do
      IO.puts("Reason: #{result["reason"]}")
    end

    if result["process_wake_event_id"] not in [nil, ""] do
      IO.puts("Wake event: #{result["process_wake_event_id"]}")
    end
  end

  defp print_agent_profiles(agents) do
    IO.puts("Agents: #{length(agents)}")
    Enum.each(agents, &print_agent_profile/1)
  end

  defp print_agent_profile(agent) do
    IO.puts("#{agent["id"]}: #{agent["display_name"] || agent["id"]}")
    IO.puts("Status: #{agent["status"] || "unknown"}")

    if agent["agent_handle"] not in [nil, ""] do
      IO.puts("Handle: #{agent["agent_handle"]}")
    end

    if agent["default_work_role"] not in [nil, ""] do
      IO.puts("Role: #{agent["default_work_role"]}")
    end

    skills = agent["skills"] || []

    if skills != [] do
      IO.puts("Skills: #{format_words(Enum.map(skills, &(&1["name"] || &1["id"])))}")
    end
  end

  defp print_agent_card(card) do
    IO.puts("#{card["agent_id"]}: #{card["display_name"] || card["agent_id"]}")
    IO.puts("Status: #{card["status"] || "unknown"}")
    IO.puts("Roles: #{format_words(card["work_roles"] || [])}")
  end

  defp print_agent_skills(agent_id, skills) do
    IO.puts("Agent skills: #{agent_id}")

    Enum.each(skills, fn skill ->
      IO.puts("- #{skill["name"] || skill["id"]}")
    end)
  end

  defp print_agent_run_events(events) do
    IO.puts("Agent run events: #{length(events)}")

    Enum.each(events, fn event ->
      IO.puts("- #{event["kind"] || event["type"]}: #{event["message"] || event["id"]}")
    end)
  end

  defp print_agent_run_replay(replay) do
    IO.puts("Agent run replay: #{replay["agent_run_id"]}")
    IO.puts("Agent: #{replay["agent_id"]}")
    IO.puts("Events: #{replay["event_count"]}")
  end

  defp print_agent_run_event(event) do
    IO.puts("Agent run event: #{event["kind"] || event["type"]}")
    IO.puts("Agent run: #{event["agent_run_id"] || "unknown"}")

    if event["message"] not in [nil, ""] do
      IO.puts("Message: #{event["message"]}")
    end
  end

  defp print_work_graph_blockers(gate) do
    blockers = gate["blockers"] || []

    if blockers != [] do
      IO.puts("")
      IO.puts("Blockers:")

      Enum.each(blockers, fn blocker ->
        IO.puts("- #{blocker["code"]}: #{blocker["message"]}")
      end)
    end
  end

  defp print_task_tool_session(session) do
    IO.puts("Tool session: #{session["session_id"]}")
    IO.puts("Task: #{session["task_ref"] || session["task_id"]}")
    IO.puts("Policy: #{session["policy_profile"]}")
    IO.puts("Enabled toolkits: #{format_words(session["enabled_toolkits"] || [])}")
    IO.puts("Direct tools: #{format_words(session["direct_tools"] || [])}")
    IO.puts("Meta tools: #{format_words(Enum.map(session["meta_tools"] || [], & &1["name"]))}")
  end

  defp print_task_tool_route(route) do
    contract = route["action_contract"] || %{}

    IO.puts("Tool route: #{route["route_id"]}")
    IO.puts("Status: #{route["status"]}")
    IO.puts("Reason: #{route["reason"]}")
    IO.puts("Tool: #{route["tool_name"]}")
    IO.puts("Kind: #{route["route_kind"] || "none"}")
    IO.puts("Effect scope: #{contract["effect_scope"] || "unknown"}")
    IO.puts("Requires approval: #{route["requires_approval"] == true}")
  end

  defp print_action_definitions(actions) do
    IO.puts("Actions: #{length(actions)}")
    Enum.each(actions, &print_action_definition_summary/1)
  end

  defp print_action_definition_summary(action) do
    approval = if action["requires_approval"], do: "approval", else: "no_approval"
    IO.puts("#{action["name"]} #{action["effect_scope"]} #{action["provider"]} #{approval}")
  end

  defp print_action_definition(action) do
    IO.puts("Action: #{action["name"]}")
    IO.puts("Provider: #{action["provider"]}")
    IO.puts("Toolkit: #{action["toolkit"]}")
    IO.puts("Effect scope: #{action["effect_scope"]}")
    IO.puts("Risk: #{action["risk_level"]}")
    IO.puts("Requires task: #{action["requires_task_ref"] == true}")
    IO.puts("Requires approval: #{action["requires_approval"] == true}")
  end

  defp print_action_execution(execution) do
    route = execution["route"] || %{}

    IO.puts("Action execution: #{execution["execution_id"]}")
    IO.puts("Status: #{execution["status"]}")
    IO.puts("Tool: #{execution["tool_name"]}")
    IO.puts("Route: #{route["status"] || "none"}")

    if execution["reason"] not in [nil, ""] do
      IO.puts("Reason: #{execution["reason"]}")
    end
  end

  defp print_action_contract(contract) do
    IO.puts("Action contract: #{contract["contract_id"]}")
    IO.puts("Tool: #{contract["tool_name"]}")
    IO.puts("Effect scope: #{contract["effect_scope"] || "unknown"}")
    IO.puts("Risk: #{contract["risk_level"] || "unknown"}")
    IO.puts("Target domain: #{contract["target_domain"] || "unknown"}")
    IO.puts("Idempotency: #{contract["idempotency_key"] || "none"}")
  end

  defp print_plan_contract(contract) do
    IO.puts("Plan contract: #{contract["plan_id"]}")
    IO.puts("Status: #{contract["status"]}")
    IO.puts("Task: #{contract["task_ref"] || contract["task_id"]}")
    IO.puts("Effect scopes: #{format_words(contract["allowed_effect_scopes"] || [])}")
    IO.puts("Allowed tools: #{format_words(contract["allowed_tools"] || [])}")
  end

  defp print_plan_gate(gate) do
    IO.puts("Plan gate: #{gate["gate_id"]}")
    IO.puts("Action: #{gate["action"]}")
    IO.puts("Reason: #{gate["reason"]}")
    IO.puts("Tool: #{gate["tool_name"]}")
    IO.puts("Effect scope: #{gate["effect_scope"] || "unknown"}")
  end

  defp print_action_preflight(preflight) do
    IO.puts("Action preflight: #{preflight["preflight_id"]}")
    IO.puts("Result: #{preflight["result"]}")
    IO.puts("Tool: #{preflight["tool_name"]}")
    IO.puts("Effect scope: #{preflight["effect_scope"] || "unknown"}")

    blocked = preflight["blocked_checks"] || []
    approvals = preflight["approval_required_checks"] || []

    if blocked != [] do
      IO.puts("Blocked checks: #{format_words(blocked)}")
    end

    if approvals != [] do
      IO.puts("Approval checks: #{format_words(approvals)}")
    end
  end

  defp print_consequence_gate(gate) do
    IO.puts("Consequence gate: #{gate["gate_id"]}")
    IO.puts("Action: #{gate["action"]}")
    IO.puts("Reason: #{gate["reason"]}")
    IO.puts("Tool: #{get_in(gate, ["action_contract", "tool_name"]) || "unknown"}")
    IO.puts("Policy: #{get_in(gate, ["policy_decision", "rule_id"]) || "none"}")
  end

  defp print_action_runtime_envelope(envelope) do
    IO.puts("Action envelope: #{envelope["envelope_id"]}")
    IO.puts("Phase: #{envelope["phase"]}")
    IO.puts("Runtime status: #{envelope["runtime_status"]}")
    IO.puts("Execution decision: #{envelope["execution_decision"]}")
    IO.puts("Tool: #{envelope["tool_name"]}")
    IO.puts("Repair directive: #{envelope["repair_directive"]}")
  end

  defp print_action_approval_request(request) do
    IO.puts("Approval request: #{request["approval_request_id"] || "none"}")
    IO.puts("Status: #{request["status"]}")
    IO.puts("Tool: #{request["tool_name"] || "unknown"}")
    IO.puts("Effect scope: #{request["effect_scope"] || "unknown"}")
    IO.puts("Risk: #{request["risk_level"] || "unknown"}")
    IO.puts("Reason: #{request["reason"] || "none"}")
  end

  defp print_action_evidence_ledger(ledger) do
    coverage = ledger["coverage"] || %{}

    IO.puts("Evidence ledger: #{ledger["ledger_id"]}")
    IO.puts("Tool: #{ledger["source_tool_name"] || "unknown"}")
    IO.puts("Task: #{ledger["task_ref"] || ledger["task_id"] || "unknown"}")
    IO.puts("Entries: #{coverage["entry_count"] || 0}")
    IO.puts("Evidence types: #{format_words(coverage["evidence_types"] || [])}")
  end

  defp print_task_memory_artifact(artifact) do
    IO.puts("Task memory artifact: #{artifact["artifact_ref"]}")
    IO.puts("Task: #{artifact["task_ref"] || artifact["task_id"] || "unknown"}")
    IO.puts("Kind: #{artifact["kind"] || "artifact"}")
    IO.puts("Title: #{artifact["title"] || "none"}")
    IO.puts("Chunks: #{artifact["chunk_count"] || 0}")
  end

  defp print_task_memory_context(packet) do
    state = packet["memory_state"] || %{}

    IO.puts("Task memory context: #{packet["packet_id"]}")
    IO.puts("Task: #{packet["task_ref"] || packet["task_id"] || "unknown"}")
    IO.puts("Budget: #{get_in(packet, ["context_budget", "budget_state"]) || "unknown"}")
    IO.puts("Runtime specs: #{state["runtime_spec_count"] || 0}")
    IO.puts("Artifacts: #{state["artifact_count"] || 0}")
    IO.puts("Evidence ledgers: #{state["evidence_ledger_count"] || 0}")
  end

  defp print_context_budget(budget) do
    IO.puts("Context budget: #{budget["budget_state"]}")
    IO.puts("Action: #{budget["action"]}")
    IO.puts("Estimated input tokens: #{budget["estimated_input_tokens"]}")
    IO.puts("Available tokens: #{budget["available_tokens"]}")
    IO.puts("Hard limit: #{budget["hard_limit_tokens"]}")
  end

  defp print_continuation_packet(packet) do
    IO.puts("Continuation packet: #{packet["packet_id"]}")
    IO.puts("Task: #{packet["previous_task_ref"] || packet["previous_task_id"] || "unknown"}")
    IO.puts("Previous run: #{packet["previous_runtime_run_id"] || "none"}")
    IO.puts("Depth: #{packet["continuation_depth"] || 1}")
    IO.puts("Context packet: #{packet["context_packet_id"] || "none"}")
  end

  defp print_capability_registry_entry(entry) do
    IO.puts("Capability registry: #{entry["capability_id"]}")
    IO.puts("Tool: #{entry["tool_name"]}")
    IO.puts("Action type: #{entry["action_type"]}")
    IO.puts("Effect scope: #{entry["effect_scope"]}")
    IO.puts("Risk: #{entry["risk_level"]}")
    IO.puts("Registered: #{entry["registered"] == true}")
  end

  defp print_capability_contract(contract) do
    IO.puts("Capability contract: #{contract["contract_id"]}")
    IO.puts("Role: #{contract["role"]}")
    IO.puts("Tool: #{contract["tool_name"] || "none"}")
    IO.puts("Effect scope: #{contract["effect_scope"]}")
    IO.puts("Required tools: #{format_words(contract["required_tools"] || [])}")
    IO.puts("Required capabilities: #{format_words(contract["required_capabilities"] || [])}")
  end

  defp print_capability_route(route) do
    IO.puts("Capability route: #{route["route_id"]}")
    IO.puts("Status: #{route["status"]}")
    IO.puts("Mode: #{route["execution_mode"]}")
    IO.puts("Target role: #{route["target_role"]}")
    IO.puts("Target agent: #{route["target_agent_id"] || "ephemeral"}")
    IO.puts("Score: #{route["score"] || 0}")
  end

  defp print_generic_plan(plan) do
    IO.puts("Generic plan: #{plan["graph_id"]}")
    IO.puts("Task: #{plan["task_ref"] || plan["task_id"]}")
    IO.puts("Phases: #{format_words(plan["node_types"] || [])}")

    plan
    |> Map.get("nodes", [])
    |> Enum.each(fn node ->
      IO.puts("#{node["node_key"]} #{node["status"]}: #{node["objective"]}")
    end)
  end

  defp format_words([]), do: "none"
  defp format_words(words), do: Enum.join(words, ", ")

  defp format_labels([]), do: "none"

  defp format_labels(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name, "color" => color} -> "#{name}(#{color})"
      %{"name" => name} -> name
      value -> to_string(value)
    end)
    |> Enum.join(", ")
  end

  defp parse_cli_checks(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, checks} ->
      case parse_cli_check(value) do
        {:ok, check} -> {:cont, {:ok, [check | checks]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :missing_check}
      {:ok, checks} -> {:ok, Enum.reverse(checks)}
      error -> error
    end
  end

  defp parse_cli_check(value) do
    case :binary.split(to_string(value), ":", [:global]) do
      [name, status] ->
        {:ok, %{"name" => name, "status" => status}}

      [name, status | evidence_parts] ->
        {:ok, %{"name" => name, "status" => status, "evidence" => Enum.join(evidence_parts, ":")}}

      _ ->
        {:error, value}
    end
  end

  defp decode_action_calls(nil), do: {:error, :missing_content}
  defp decode_action_calls(""), do: {:error, :missing_content}

  defp decode_action_calls(content) do
    case Jason.decode(content) do
      {:ok, calls} when is_list(calls) -> {:ok, calls}
      {:ok, _value} -> {:error, :expected_json_array}
      {:error, reason} -> {:error, Exception.message(reason)}
    end
  end

  defp maybe_put(map, _key, value) when value in [nil, "", []], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_opt(opts, _key, value) when value in [nil, "", []], do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp standalone? do
    Code.ensure_loaded?(Burrito.Util) and Burrito.Util.running_standalone?()
  end

  defp parse_opts(args) do
    {parsed, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          home: :string,
          workspace: :string,
          provider: :string,
          model: :string,
          base_url: :string,
          api_key_env: :string,
          env_file: :string,
          prompt: :string,
          name: :string,
          handle: :string,
          title: :string,
          description: :string,
          status: :string,
          priority: :string,
          estimate: :string,
          kind: :string,
          parent: :string,
          due_date: :string,
          scheduled_start_at: :string,
          assignee: :string,
          label: :string,
          enabled_toolkit: :string,
          disabled_toolkit: :string,
          disabled_tool: :string,
          direct_tool: :string,
          color: :string,
          type: :string,
          graph_id: :string,
          task: :string,
          spec_id: :string,
          message: :string,
          mode: :string,
          content: :string,
          content_limit: :integer,
          check: :string,
          summary: :string,
          agent: :string,
          limit: :integer,
          max_agents_per_event: :integer,
          max_concurrent_agents: :integer,
          group_token_budget: :integer,
          token_budget: :integer,
          max_total_tokens: :integer,
          task_complexity: :string,
          event_kind: :string,
          idempotency_key: :string,
          request_id: :string,
          target_skill: :string,
          verification_required: :boolean,
          review_strategy: :string,
          allow_ephemeral_verifier: :boolean,
          verifier_agent_id: :string,
          later_outcome: :string,
          completion_decision: :string,
          verification_status: :string,
          can_finish: :boolean,
          max_attempts: :integer,
          stale_after_seconds: :integer,
          recovery_cooldown_seconds: :integer,
          auto_continue: :boolean,
          max_continuation_depth: :integer,
          retry_on_failure: :boolean,
          allow_workspace_durable: :boolean,
          approval_status: :string,
          result_status: :string,
          result_preview: :string,
          artifact_ref: :string,
          source: :string,
          previous_run_id: :string,
          previous_agent_run_id: :string,
          previous_agent_work_id: :string,
          agent_work_id: :string,
          agent_run_id: :string,
          estimated_input_tokens: :integer,
          context_window: :integer,
          max_tool_calls: :integer,
          max_wall_clock_seconds: :integer,
          hard_limit_tokens: :integer,
          soft_limit_tokens: :integer,
          critical_limit_tokens: :integer,
          output_reserve_tokens: :integer,
          tool_reserve_tokens: :integer,
          workspace_status: :string,
          network_status: :string,
          network_enabled: :boolean,
          decision: :string,
          decided_by: :string,
          reason_code: :string,
          reason: :string,
          risk_level: :string,
          force_approval_request: :boolean,
          role: :string,
          work_role: :string,
          tool: :string,
          skill: :string,
          tool_call_id: :string,
          agent_ref: :string,
          instructions: :string,
          path: :string,
          query: :string,
          command: :string,
          url: :string,
          managed_process_id: :string,
          process_id: :string,
          sandbox_pid: :string,
          status_path: :string,
          exit_code: :integer,
          wait_for_exit: :boolean,
          notify_on_exit: :boolean,
          effect_scope: :string,
          allowed_tool: :string,
          required_tool: :string,
          capability: :string,
          input_artifact: :string,
          expected_output: :string,
          include_content: :boolean,
          yes: :boolean,
          json: :boolean,
          api_key_stdin: :boolean
        ],
        aliases: [y: :yes]
      )

    {parsed, rest}
  end

  defp with_approval(opts) do
    if opts[:yes] do
      Keyword.put(opts, :approval, :always_approve)
    else
      opts
    end
  end

  defp maybe_update_provider(providers, opts) do
    provider = opts[:provider]

    if provider in [nil, ""] do
      providers
    else
      provider_config =
        case provider do
          "openai" ->
            %{
              "type" => "openai",
              "model" => opts[:model] || "gpt-5.2",
              "api_key_env" => opts[:api_key_env] || "OPENAI_API_KEY"
            }

          "openrouter" ->
            %{
              "type" => "openrouter",
              "model" => opts[:model] || "openai/gpt-4o-mini",
              "api_key_env" => opts[:api_key_env] || "OPENROUTER_API_KEY",
              "base_url" => opts[:base_url] || "https://openrouter.ai/api/v1",
              "http_referer" => "https://holtworks.ai",
              "app_title" => "HoltWorks",
              "max_tokens" => 1_200,
              "temperature" => 0.2
            }

          "ollama" ->
            %{
              "type" => "ollama",
              "model" => opts[:model] || "llama3.1",
              "base_url" => opts[:base_url] || "http://127.0.0.1:11434"
            }

          _ ->
            %{"type" => "local", "model" => "local-planner"}
        end

      providers
      |> put_in(["providers", provider], provider_config)
      |> Map.put("default_provider", provider)
    end
  end

  defp format_created([]), do: "none; existing files kept"
  defp format_created(created), do: Enum.join(created, ", ")

  defp maybe_override_model(provider, opts) do
    case opts[:model] do
      nil -> provider
      model -> Map.put(provider, "model", model)
    end
  end

  defp maybe_shrink_smoke_response(%{"type" => type} = provider)
       when type in ["openrouter", "openai", "ollama"] do
    Map.put(provider, "max_tokens", 64)
  end

  defp maybe_shrink_smoke_response(provider), do: provider

  defp run_llm_smoke(provider, opts) do
    prompt = opts[:prompt] || "Reply exactly: HoltWorks LLM smoke test ok."

    case Models.chat(provider, Models.smoke_messages(prompt), opts) do
      {:ok, response} ->
        IO.puts("Provider: #{response["provider"]}")
        IO.puts("Model: #{response["model"]}")
        IO.puts("")
        IO.puts(String.trim(response["content"]))
        0

      {:error, reason} ->
        IO.puts(:stderr, "LLM smoke test failed: #{inspect(reason)}")
        1
    end
  end

  defp maybe_read_key_from_stdin(opts, provider \\ nil) do
    if opts[:api_key_stdin] do
      provider = provider || default_cli_provider(opts)
      env = Map.get(provider, "api_key_env")

      if is_binary(env) and env != "" and System.get_env(env) in [nil, ""] do
        case HoltWorks.Env.read_key_from_stdin(env) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "Could not read #{env} from stdin: #{inspect(reason)}")
        end
      end
    end

    :ok
  end

  defp default_cli_provider(opts) do
    home = Paths.home(opts)
    Config.bootstrap(home: home)
    Models.default_provider(home)
  end
end
