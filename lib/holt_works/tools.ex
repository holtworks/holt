defmodule HoltWorks.Tools do
  @moduledoc """
  Local tool registry and execution policy.
  """

  alias HoltWorks.{
    Agents,
    Approvals,
    Clock,
    Memory,
    Pages,
    Paths,
    RepairRuns,
    ResearchClaims,
    Skills,
    TextMatch,
    WebSearch
  }

  alias HoltWorks.Tasks.{ChildAgentContract, RuntimeContracts}

  @tools [
    %{
      "name" => "list_files",
      "description" => "List files inside the workspace.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "read_file",
      "description" => "Read a UTF-8 text file from the workspace.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "write_file",
      "description" => "Write a UTF-8 text file inside the workspace.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "append_file",
      "description" => "Append UTF-8 text to a file inside the workspace.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "search_files",
      "description" => "Search text files inside the workspace.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "run_command",
      "description" => "Run a shell command inside the workspace.",
      "risk" => "execute",
      "requires_approval" => true
    },
    %{
      "name" => "fetch_url",
      "description" => "Fetch a URL over the network.",
      "risk" => "network",
      "requires_approval" => true
    },
    %{
      "name" => "search_web",
      "description" =>
        "Search the web for current information and optionally persist a structured research claim.",
      "risk" => "network",
      "requires_approval" => true
    },
    %{
      "name" => "ask_user",
      "description" => "Ask the user for input.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "ask_user_question",
      "description" => "Ask the user a structured question and wait for a response.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "delegate_to_agent",
      "description" => "Prepare a structured ephemeral child-agent delegation contract.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "set_page_title",
      "description" => "Set the active page title or a specific local page title.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "create_page",
      "description" => "Create a local page record backed by a document file.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "write_to_document",
      "description" => "Write content to a local document page.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "save_memory",
      "description" => "Save a local memory entry.",
      "risk" => "write",
      "requires_approval" => false
    },
    %{
      "name" => "search_memory",
      "description" => "Search local memory entries.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "remember_about_user",
      "description" => "Save a durable user fact, preference, context, or goal.",
      "risk" => "write",
      "requires_approval" => false
    },
    %{
      "name" => "forget_about_user",
      "description" => "Forget user memories matching a specific substring.",
      "risk" => "write",
      "requires_approval" => false
    },
    %{
      "name" => "list_user_memories",
      "description" => "List scoped user memories.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "search_user_memory",
      "description" => "Search scoped user memories.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "remember_for_project",
      "description" => "Save a short project memory note.",
      "risk" => "write",
      "requires_approval" => false
    },
    %{
      "name" => "save_plan",
      "description" => "Save a long-form project plan for future sessions.",
      "risk" => "write",
      "requires_approval" => false
    },
    %{
      "name" => "save_research",
      "description" => "Save long-form project research with optional sources.",
      "risk" => "write",
      "requires_approval" => false
    },
    %{
      "name" => "recall_project_memory",
      "description" => "Search project notes, plans, and research summaries.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "read_project_memory",
      "description" => "Read the full body of a project memory entry.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "list_skills",
      "description" => "List saved reusable workflow skills.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "load_skill",
      "description" => "Load the full body of a saved skill.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "save_skill",
      "description" => "Save a reusable workflow skill.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "update_skill",
      "description" => "Update an existing reusable workflow skill.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "run_skill_script",
      "description" => "Execute a script owned by a saved skill.",
      "risk" => "execute",
      "requires_approval" => true
    },
    %{
      "name" => "list_agents",
      "description" => "List assignable local agent profiles.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "create_agent",
      "description" => "Create a local assignable agent profile.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "update_agent",
      "description" => "Update a local agent profile.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "suspend_agent",
      "description" => "Suspend a local agent profile.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "resume_agent",
      "description" => "Resume a suspended local agent profile.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "delete_agent",
      "description" => "Delete a local agent profile after explicit confirmation.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "list_agent_cards",
      "description" => "List compact routing cards for local agents.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "get_agent_card",
      "description" => "Load one compact routing card for a local agent.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "list_agent_skills",
      "description" => "List skills declared by one local agent profile.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "invoke_agent",
      "description" => "Prepare a structured invocation contract for a local persisted agent.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "start_repair_run",
      "description" => "Start a structured local repair run.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "get_repair_run",
      "description" => "Read the current state of a local repair run.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "record_repair_run_artifact",
      "description" => "Record a typed artifact on a local repair run.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "reconcile_repair_prediction",
      "description" => "Compare a repair prediction with an explicit observation.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "score_repair_predictions",
      "description" => "Score repair prediction convergence from structured reconciliations.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "choose_repair_strategy",
      "description" => "Choose the strategy for a local repair run.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "draft_repair_architecture_plan",
      "description" => "Draft and optionally record a structured repair architecture plan.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "draft_repair_blast_radius",
      "description" => "Draft and optionally record a structured blast-radius report.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "draft_repair_original_issue_check",
      "description" => "Draft and optionally record an original-issue verification check.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "execute_repair_original_issue_check",
      "description" => "Record explicit original-issue check evidence.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "execute_repair_impact_check",
      "description" => "Record explicit blast-radius impact check evidence.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "draft_repair_related_issue_sweep",
      "description" => "Draft and optionally record a structured related-issue sweep.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "begin_repair_implementation",
      "description" => "Open implementation after repair gates pass.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "approve_repair_gate",
      "description" => "Record explicit approval for a high-risk repair run.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "complete_repair_run",
      "description" => "Complete a repair run after structured completion gates pass.",
      "risk" => "write",
      "requires_approval" => true
    }
  ]

  def definitions, do: @tools

  def names do
    Enum.map(@tools, & &1["name"])
  end

  def get(name) do
    Enum.find(@tools, &(&1["name"] == name))
  end

  def execute(name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    case get(name) do
      nil ->
        {:error, :unknown_tool}

      tool ->
        maybe_execute(tool, args, opts)
    end
  end

  defp maybe_execute(tool, args, opts) do
    risk = effective_risk(tool, args, opts)

    if risk_requires_approval?(risk, tool) do
      request = %{
        "tool" => tool["name"],
        "risk" => risk,
        "reason" => Map.get(args, "reason", default_reason(tool)),
        "args" => args
      }

      case Approvals.request(request, opts) do
        {:ok, %{"status" => "approved"}} -> do_execute(tool["name"], args, opts)
        {:ok, _record} -> {:error, :approval_denied}
        error -> error
      end
    else
      do_execute(tool["name"], args, opts)
    end
  end

  defp do_execute("list_files", args, opts) do
    root = Paths.workspace_root(opts)
    limit = Map.get(args, "limit", 200)

    files =
      root
      |> walk_files(limit)
      |> Enum.map(&Path.relative_to(&1, root))

    {:ok, %{"files" => files}}
  end

  defp do_execute("read_file", %{"path" => path}, opts) do
    with {:ok, target} <- safe_path(path, opts),
         {:ok, body} <- File.read(target),
         :ok <- text_file(body) do
      {:ok, %{"path" => Path.relative_to(target, Paths.workspace_root(opts)), "content" => body}}
    end
  end

  defp do_execute("write_file", %{"path" => path, "content" => content}, opts) do
    with {:ok, target} <- safe_path(path, opts) do
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, to_string(content))

      {:ok,
       %{
         "path" => Path.relative_to(target, Paths.workspace_root(opts)),
         "bytes" => byte_size(to_string(content))
       }}
    end
  end

  defp do_execute("append_file", %{"path" => path, "content" => content}, opts) do
    with {:ok, target} <- safe_path(path, opts) do
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, to_string(content), [:append])

      {:ok,
       %{
         "path" => Path.relative_to(target, Paths.workspace_root(opts)),
         "bytes" => byte_size(to_string(content))
       }}
    end
  end

  defp do_execute("search_files", %{"query" => query}, opts) do
    root = Paths.workspace_root(opts)

    matches =
      root
      |> walk_files(500)
      |> Enum.reject(&run_log_path?/1)
      |> Enum.flat_map(&search_file(&1, root, query))
      |> Enum.take(100)

    {:ok, %{"matches" => matches}}
  end

  defp do_execute("run_command", %{"command" => command}, opts) do
    root = Paths.workspace_root(opts)
    command = to_string(command)

    {output, exit_code} =
      System.cmd("/bin/sh", ["-c", command],
        cd: root,
        stderr_to_stdout: true,
        env: [{"HOLTWORKS", "1"}]
      )

    {:ok, %{"command" => command, "exit_code" => exit_code, "output" => output}}
  end

  defp do_execute("fetch_url", %{"url" => url}, _opts) do
    case Req.get(to_string(url), receive_timeout: 15_000) do
      {:ok, response} ->
        {:ok,
         %{
           "url" => url,
           "status" => response.status,
           "body" => response.body |> to_string() |> String.slice(0, 20_000)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_execute("search_web", %{"query" => _query} = args, opts) do
    with :ok <- ResearchClaims.validate_recording_request(args),
         {:ok, search_result} <- WebSearch.search_web(args, opts),
         {:ok, claim_result} <-
           ResearchClaims.maybe_record("search_web", args, opts, search_result) do
      {:ok,
       search_result
       |> Map.merge(claim_result)
       |> maybe_append_claim_status()}
    end
  end

  defp do_execute("ask_user", %{"question" => question}, _opts) do
    answer = IO.gets("#{question}\n> ")
    {:ok, %{"answer" => String.trim(to_string(answer))}}
  end

  defp do_execute("ask_user_question", args, _opts) do
    with {:ok, question} <- required_agent_text(args, "question") do
      {:ok,
       %{
         "schema_version" => "holtworks_user_question/v1",
         "status" => "await_user",
         "question" => question,
         "description" => optional_agent_text(args, "description"),
         "options" => normalize_question_options(args["options"]),
         "created_at" => Clock.iso_now()
       }
       |> reject_empty()}
    end
  end

  defp do_execute("delegate_to_agent", args, _opts) do
    with {:ok, role} <- required_agent_text(args, "role"),
         {:ok, system_prompt} <- required_agent_text(args, "system_prompt"),
         {:ok, instructions} <- required_agent_text(args, "instructions") do
      delegation_args =
        args
        |> Map.put("role", role)
        |> Map.put("system_prompt", system_prompt)
        |> Map.put("instructions", instructions)

      child_contract =
        ChildAgentContract.build(%{
          "tool_name" => "delegate_to_agent",
          "arguments" => delegation_args
        })

      {:ok,
       %{
         "schema_version" => "holtworks_agent_delegation/v1",
         "delegation_id" => Clock.id("agent_delegation"),
         "status" => "ready",
         "role" => role,
         "work_role" => optional_agent_text(args, "work_role"),
         "system_prompt" => system_prompt,
         "instructions" => instructions,
         "page_id" => optional_agent_text(args, "page_id"),
         "target_agent_id" => optional_agent_text(args, "target_agent_id"),
         "target_skill" => optional_agent_text(args, "target_skill"),
         "input_artifacts" => normalize_agent_list(args["input_artifacts"]),
         "expected_output_artifacts" => normalize_agent_list(args["expected_output_artifacts"]),
         "validation_contract" => optional_agent_text(args, "validation_contract"),
         "parent_task_id" => optional_agent_text(args, "parent_task_id"),
         "handoff_requirements" => normalize_agent_list(args["handoff_requirements"]),
         "allowed_tools" => normalize_agent_list(args["allowed_tools"]),
         "max_autonomy" => optional_agent_text(args, "max_autonomy"),
         "child_agent_contract" => child_contract,
         "created_at" => Clock.iso_now()
       }
       |> reject_empty()}
    end
  end

  defp do_execute("set_page_title", args, opts), do: Pages.set_title(args, opts)
  defp do_execute("create_page", args, opts), do: Pages.create(args, opts)
  defp do_execute("write_to_document", args, opts), do: Pages.write_document(args, opts)

  defp do_execute("save_memory", %{"text" => text} = args, opts) do
    kind = Map.get(args, "kind", "fact")
    Memory.save(kind, text, opts)
  end

  defp do_execute("search_memory", %{"query" => query}, opts) do
    {:ok, %{"matches" => Memory.search(query, opts)}}
  end

  defp do_execute("remember_about_user", args, opts) do
    Memory.remember_user(args, opts)
  end

  defp do_execute("forget_about_user", args, opts) do
    Memory.forget_user(args, opts)
  end

  defp do_execute("list_user_memories", args, opts) do
    {:ok, %{"memories" => Memory.list_user(args, opts)}}
  end

  defp do_execute("search_user_memory", args, opts) do
    {:ok, %{"matches" => Memory.search_user(args, opts)}}
  end

  defp do_execute("remember_for_project", args, opts) do
    Memory.remember_project(args, opts)
  end

  defp do_execute("save_plan", args, opts) do
    Memory.save_project_plan(args, opts)
  end

  defp do_execute("save_research", args, opts) do
    Memory.save_project_research(args, opts)
  end

  defp do_execute("recall_project_memory", args, opts) do
    {:ok, %{"memories" => Memory.recall_project(args, opts)}}
  end

  defp do_execute("read_project_memory", args, opts) do
    Memory.read_project(args, opts)
  end

  defp do_execute("list_skills", args, opts) do
    {:ok, %{"skills" => Skills.search(args, opts)}}
  end

  defp do_execute("load_skill", args, opts) do
    Skills.load(args, opts)
  end

  defp do_execute("save_skill", args, opts) do
    Skills.save(args, opts)
  end

  defp do_execute("update_skill", args, opts) do
    Skills.update(args, opts)
  end

  defp do_execute("run_skill_script", args, opts) do
    Skills.run_script(args, opts)
  end

  defp do_execute("list_agents", args, opts) do
    root = Paths.workspace_root(opts)
    status = agent_status(args)

    agents =
      root
      |> Agents.list_for_root()
      |> filter_agent_status(status)

    {:ok, %{"agents" => agents, "count" => length(agents)}}
  end

  defp do_execute("create_agent", args, opts) do
    opts
    |> Paths.workspace_root()
    |> Agents.create(args)
  end

  defp do_execute("update_agent", args, opts) do
    with {:ok, agent_id} <- agent_identifier(args) do
      opts
      |> Paths.workspace_root()
      |> Agents.update(agent_id, drop_agent_identifier_args(args))
    end
  end

  defp do_execute("suspend_agent", args, opts) do
    with {:ok, agent_id} <- agent_identifier(args) do
      opts
      |> Paths.workspace_root()
      |> Agents.suspend(agent_id, drop_agent_identifier_args(args))
    end
  end

  defp do_execute("resume_agent", args, opts) do
    with {:ok, agent_id} <- agent_identifier(args) do
      opts
      |> Paths.workspace_root()
      |> Agents.resume(agent_id, drop_agent_identifier_args(args))
    end
  end

  defp do_execute("delete_agent", args, opts) do
    with true <- confirmed?(Map.get(args, "confirm")),
         {:ok, agent_id} <- agent_identifier(args) do
      opts
      |> Paths.workspace_root()
      |> Agents.delete(agent_id, drop_agent_identifier_args(args))
    else
      false -> {:error, :delete_requires_confirm}
      error -> error
    end
  end

  defp do_execute("list_agent_cards", args, opts) do
    root = Paths.workspace_root(opts)
    cards = Agents.list_cards(root, status: agent_status(args))
    {:ok, %{"agent_cards" => cards, "count" => length(cards)}}
  end

  defp do_execute("get_agent_card", args, opts) do
    with {:ok, agent_id} <- agent_identifier(args) do
      opts
      |> Paths.workspace_root()
      |> Agents.card(agent_id)
    end
  end

  defp do_execute("list_agent_skills", args, opts) do
    with {:ok, agent_id} <- agent_identifier(args),
         {:ok, skills} <-
           opts
           |> Paths.workspace_root()
           |> Agents.list_skills(agent_id) do
      {:ok, %{"skills" => skills}}
    end
  end

  defp do_execute("invoke_agent", args, opts) do
    root = Paths.workspace_root(opts)

    with {:ok, agent_id} <- agent_identifier(args),
         {:ok, profile} <- Agents.get(root, agent_id),
         :ok <- ensure_agent_invokable(profile),
         {:ok, instructions} <- required_agent_text(args, "instructions"),
         {:ok, target_skill} <- required_agent_text(args, "target_skill"),
         {:ok, validation_contract} <- required_agent_text(args, "validation_contract") do
      invocation_args =
        args
        |> Map.put("agent_id", profile["id"])
        |> Map.put("target_agent_id", profile["id"])
        |> Map.put("target_skill", target_skill)
        |> Map.put("validation_contract", validation_contract)

      child_contract =
        HoltWorks.Tasks.ChildAgentContract.build(%{
          "tool_name" => "invoke_agent",
          "arguments" => invocation_args
        })

      {:ok,
       %{
         "schema_version" => "holtworks_agent_invocation/v1",
         "invocation_id" => Clock.id("agent_invocation"),
         "status" => "ready",
         "agent_id" => profile["id"],
         "agent_card" => Agents.profile_card(profile),
         "instructions" => instructions,
         "target_skill" => target_skill,
         "work_role" => optional_agent_text(args, "work_role"),
         "input_artifacts" => normalize_agent_list(args["input_artifacts"]),
         "expected_output_artifacts" => normalize_agent_list(args["expected_output_artifacts"]),
         "handoff_requirements" => normalize_agent_list(args["handoff_requirements"]),
         "allowed_tools" => normalize_agent_list(args["allowed_tools"]),
         "max_autonomy" => optional_agent_text(args, "max_autonomy"),
         "validation_contract" => validation_contract,
         "child_agent_contract" => child_contract,
         "created_at" => Clock.iso_now()
       }
       |> reject_empty()}
    end
  end

  defp do_execute("start_repair_run", args, opts), do: RepairRuns.start(args, opts)

  defp do_execute("get_repair_run", args, opts) do
    with {:ok, repair_run_id} <- repair_run_id(args),
         {:ok, repair_run} <- RepairRuns.get(repair_run_id, opts) do
      {:ok, %{"repair_run" => repair_run}}
    end
  end

  defp do_execute("record_repair_run_artifact", args, opts),
    do: RepairRuns.record_artifact(args, opts)

  defp do_execute("reconcile_repair_prediction", args, opts),
    do: RepairRuns.reconcile_prediction(args, opts)

  defp do_execute("score_repair_predictions", args, opts),
    do: RepairRuns.score_predictions(args, opts)

  defp do_execute("choose_repair_strategy", args, opts),
    do: RepairRuns.choose_strategy(args, opts)

  defp do_execute("draft_repair_architecture_plan", args, opts),
    do: RepairRuns.draft_architecture_plan(args, opts)

  defp do_execute("draft_repair_blast_radius", args, opts),
    do: RepairRuns.draft_blast_radius(args, opts)

  defp do_execute("draft_repair_original_issue_check", args, opts),
    do: RepairRuns.draft_original_issue_check(args, opts)

  defp do_execute("execute_repair_original_issue_check", args, opts),
    do: RepairRuns.execute_original_issue_check(args, opts)

  defp do_execute("execute_repair_impact_check", args, opts),
    do: RepairRuns.execute_impact_check(args, opts)

  defp do_execute("draft_repair_related_issue_sweep", args, opts),
    do: RepairRuns.draft_related_issue_sweep(args, opts)

  defp do_execute("begin_repair_implementation", args, opts),
    do: RepairRuns.begin_implementation(args, opts)

  defp do_execute("approve_repair_gate", args, opts), do: RepairRuns.approve_gate(args, opts)

  defp do_execute("complete_repair_run", args, opts), do: RepairRuns.complete(args, opts)

  defp do_execute(_name, _args, _opts), do: {:error, :invalid_tool_args}

  defp agent_status(args) do
    status = optional_agent_text(args, "status") || optional_agent_text(args, "status_filter")
    if status in [nil, "", "all"], do: nil, else: status
  end

  defp filter_agent_status(agents, nil), do: agents
  defp filter_agent_status(agents, status), do: Enum.filter(agents, &(&1["status"] == status))

  defp agent_identifier(args) when is_map(args) do
    [
      args["agent_id"],
      args["id"],
      args["agent_ref"],
      args["ref"],
      args["handle"]
    ]
    |> Enum.find_value(fn
      value when value in [nil, ""] -> nil
      value -> optional_agent_text(%{"value" => value}, "value")
    end)
    |> case do
      nil -> {:error, :agent_id_required}
      agent_id -> {:ok, agent_id}
    end
  end

  defp agent_identifier(_args), do: {:error, :agent_id_required}

  defp repair_run_id(args) when is_map(args) do
    case optional_agent_text(args, "repair_run_id") || optional_agent_text(args, "id") do
      nil -> {:error, :repair_run_id_required}
      id -> {:ok, id}
    end
  end

  defp repair_run_id(_args), do: {:error, :repair_run_id_required}

  defp drop_agent_identifier_args(args) do
    Map.drop(args, [
      "id",
      "agent_id",
      "agent_ref",
      "ref",
      "handle",
      "confirm"
    ])
  end

  defp confirmed?(true), do: true
  defp confirmed?("true"), do: true
  defp confirmed?(_value), do: false

  defp ensure_agent_invokable(%{"status" => "active", "lifecycle_state" => "active"}), do: :ok
  defp ensure_agent_invokable(%{"status" => "active"}), do: :ok
  defp ensure_agent_invokable(_profile), do: {:error, :agent_not_invokable}

  defp required_agent_text(args, key) do
    case optional_agent_text(args, key) do
      nil -> {:error, {:required, key}}
      text -> {:ok, text}
    end
  end

  defp optional_agent_text(map, key, default \\ nil)

  defp optional_agent_text(map, key, default) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      nil ->
        default

      value ->
        value
        |> to_string()
        |> String.trim()
        |> case do
          "" -> default
          text -> text
        end
    end
  end

  defp optional_agent_text(_map, _key, default), do: default

  defp normalize_agent_list(nil), do: []

  defp normalize_agent_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_agent_list/1)
    |> Enum.uniq()
  end

  defp normalize_agent_list(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_question_options(nil), do: []

  defp normalize_question_options(value) when is_list(value) do
    value
    |> Enum.map(&normalize_question_option/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_question_options(value), do: normalize_question_options([value])

  defp normalize_question_option(value) when is_map(value) do
    option = RuntimeContracts.string_keys(value)
    label = optional_agent_text(option, "label") || optional_agent_text(option, "title")
    value = optional_agent_text(option, "value") || label

    %{
      "label" => label || value,
      "value" => value,
      "description" => optional_agent_text(option, "description")
    }
    |> reject_empty()
  end

  defp normalize_question_option(value) do
    text = value |> to_string() |> String.trim()

    if text == "" do
      %{}
    else
      %{"label" => text, "value" => text}
    end
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp maybe_append_claim_status(
         %{"text" => text, "research_claim_saved" => true, "research_claim" => %{} = claim} =
           result
       ) do
    Map.put(
      result,
      "text",
      Enum.join([text, "", "---", "Research claim saved as #{claim["id"]}."], "\n")
    )
  end

  defp maybe_append_claim_status(result), do: result

  defp effective_risk(%{"name" => "read_file"} = tool, %{"path" => path}, _opts) do
    if secret_path?(path), do: "secret", else: tool["risk"]
  end

  defp effective_risk(tool, _args, _opts), do: tool["risk"]

  defp risk_requires_approval?("secret", _tool), do: true
  defp risk_requires_approval?(_risk, %{"requires_approval" => value}), do: value == true

  defp default_reason(tool) do
    "The agent requested #{tool["name"]}."
  end

  defp safe_path(path, opts) do
    root =
      opts
      |> Paths.workspace_root()
      |> Path.expand()

    target =
      path
      |> to_string()
      |> Path.expand(root)

    if under_root?(target, root) do
      {:ok, target}
    else
      {:error, :path_outside_workspace}
    end
  end

  defp under_root?(target, root) do
    root
    |> Path.split()
    |> :lists.prefix(Path.split(target))
  end

  defp run_log_path?(path) do
    path
    |> Path.split()
    |> run_log_components?()
  end

  defp run_log_components?([".holtworks", "runs" | _rest]), do: true
  defp run_log_components?([_part | rest]), do: run_log_components?(rest)
  defp run_log_components?([]), do: false

  defp walk_files(root, limit) do
    root
    |> do_walk([])
    |> Enum.reject(&File.dir?/1)
    |> Enum.take(limit)
  end

  defp do_walk(path, acc) do
    cond do
      skip_dir?(path) ->
        acc

      File.dir?(path) ->
        case File.ls(path) do
          {:ok, names} ->
            Enum.reduce(names, acc, fn name, next_acc ->
              do_walk(Path.join(path, name), next_acc)
            end)

          _ ->
            acc
        end

      true ->
        [path | acc]
    end
  end

  defp skip_dir?(path) do
    name = Path.basename(path)
    name in [".git", "_build", "deps", "node_modules", "burrito_out"]
  end

  defp search_file(path, root, query) do
    with {:ok, body} <- File.read(path),
         :ok <- text_file(body),
         true <- TextMatch.matches?(body, query) do
      [
        %{
          "path" => Path.relative_to(path, root),
          "preview" => body |> String.slice(0, 500)
        }
      ]
    else
      _ -> []
    end
  end

  defp text_file(body) do
    cond do
      byte_size(body) > 500_000 -> {:error, :file_too_large}
      String.valid?(body) -> :ok
      true -> {:error, :binary_file}
    end
  end

  defp secret_path?(path) do
    components =
      path
      |> to_string()
      |> String.downcase()
      |> Path.split()

    basename = List.last(components)

    basename in secret_file_names() or
      Enum.any?(components, &(&1 in secret_directories())) or
      Path.extname(basename) in secret_extensions()
  end

  defp secret_file_names do
    [
      ".env",
      ".env.local",
      ".envrc",
      "id_rsa",
      "id_ed25519",
      "credentials",
      "credentials.json",
      "secrets.json",
      "token",
      "token.json"
    ]
  end

  defp secret_directories, do: [".ssh", ".gnupg", ".aws", ".config"]
  defp secret_extensions, do: [".pem", ".key", ".p12", ".pfx"]
end
