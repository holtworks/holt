defmodule Holt.LocalActions do
  @moduledoc """
  Local action registry and execution policy.
  """

  alias Holt.{
    Agents,
    Approvals,
    Clock,
    FileDiff,
    Memory,
    Pages,
    Paths,
    RepairRuns,
    ResearchClaims,
    Skills,
    TextMatch,
    WebSearch
  }

  alias Holt.Tasks.ChildAgentContract

  @actions [
    %{
      "name" => "list",
      "description" => "List files inside the workspace.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "read",
      "description" => "Read a UTF-8 text file from the workspace.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "write",
      "description" =>
        "Write a UTF-8 text file inside the workspace only when the user explicitly asks to save, create, or modify a file on disk. Do not use for content that can be returned directly in chat.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "append",
      "description" =>
        "Append UTF-8 text to a workspace file only when the user explicitly asks to update an existing file on disk. Do not use for content that can be returned directly in chat.",
      "risk" => "write",
      "requires_approval" => true
    },
    %{
      "name" => "search",
      "description" => "Search text files inside the workspace.",
      "risk" => "read",
      "requires_approval" => false
    },
    %{
      "name" => "run",
      "description" => "Run a shell command inside the workspace.",
      "risk" => "execute",
      "requires_approval" => true
    },
    %{
      "name" => "fetch",
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
      "name" => "ask",
      "description" =>
        "Ask the user a structured question and wait for a response. Use this action for every follow-up question, clarification, option selection, or prompt that expects another user response; assistant content is terminal output and must not contain user-input prompts.",
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
      "description" => "Set a local page title.",
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
      "name" => "remember",
      "description" => "Save a local memory entry.",
      "risk" => "write",
      "requires_approval" => false
    },
    %{
      "name" => "recall",
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

  def definitions, do: @actions

  def names do
    Enum.map(@actions, & &1["name"])
  end

  def get(name) do
    Enum.find(@actions, &(&1["name"] == name))
  end

  def execute(name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    case get(name) do
      nil ->
        {:error, :unknown_action}

      action ->
        maybe_execute(action, args, opts)
    end
  end

  defp maybe_execute(action, args, opts) do
    risk = effective_risk(action, args, opts)

    if risk_requires_approval?(risk, action) do
      request = %{
        "action" => action["name"],
        "risk" => risk,
        "reason" => Map.get(args, "reason", default_reason(action)),
        "args" => args
      }

      case Approvals.request(request, opts) do
        {:ok, %{"status" => "approved"}} -> do_execute(action["name"], args, opts)
        {:ok, _record} -> {:error, :approval_denied}
        error -> error
      end
    else
      do_execute(action["name"], args, opts)
    end
  end

  defp do_execute("list", args, opts) do
    root = Paths.workspace_root(opts)
    limit = Map.get(args, "limit", 200)

    files =
      root
      |> walk_files(limit)
      |> Enum.map(&Path.relative_to(&1, root))

    {:ok, %{"files" => files}}
  end

  defp do_execute("read", %{"path" => path}, opts) do
    with {:ok, target} <- safe_path(path, opts),
         {:ok, body} <- File.read(target),
         :ok <- text_file(body) do
      {:ok, %{"path" => Path.relative_to(target, Paths.workspace_root(opts)), "content" => body}}
    end
  end

  defp do_execute("write", %{"path" => path, "content" => content}, opts) do
    with {:ok, target} <- safe_path(path, opts) do
      root = Paths.workspace_root(opts)
      before = FileDiff.read_existing_text(target)
      content = to_string(content)

      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)

      {:ok, file_change_result(target, root, before, content)}
    end
  end

  defp do_execute("append", %{"path" => path, "content" => content}, opts) do
    with {:ok, target} <- safe_path(path, opts) do
      root = Paths.workspace_root(opts)
      before = FileDiff.read_existing_text(target)
      content = to_string(content)
      after_content = existing_text(before) <> content

      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content, [:append])

      {:ok, file_change_result(target, root, before, after_content, byte_size(content))}
    end
  end

  defp do_execute("search", %{"query" => query}, opts) do
    root = Paths.workspace_root(opts)

    matches =
      root
      |> walk_files(500)
      |> Enum.reject(&run_log_path?/1)
      |> Enum.flat_map(&search_file(&1, root, query))
      |> Enum.take(100)

    {:ok, %{"matches" => matches}}
  end

  defp do_execute("run", %{"command" => command}, opts) do
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

  defp do_execute("fetch", %{"url" => url}, _opts) do
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

  defp do_execute("ask", args, _opts) do
    with {:ok, question} <- required_agent_text(args, "question"),
         {:ok, options} <- normalize_question_options(args["options"]) do
      {:ok,
       %{
         "schema_version" => "holt_user_question/v1",
         "status" => "await_user",
         "question" => question,
         "description" => optional_agent_text(args, "description"),
         "options" => options,
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
        |> Map.put("child_ref", role)
        |> Map.put("system_prompt", system_prompt)
        |> Map.put("instructions", instructions)

      child_contract =
        ChildAgentContract.build(%{
          "action" => "delegate_to_agent",
          "arguments" => delegation_args
        })

      {:ok,
       %{
         "schema_version" => "holt_agent_delegation/v1",
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
         "allowed_actions" => normalize_agent_list(args["allowed_actions"]),
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

  defp do_execute("remember", %{"text" => text} = args, opts) do
    kind = Map.get(args, "kind", "fact")
    Memory.save(kind, text, opts)
  end

  defp do_execute("recall", %{"query" => query}, opts) do
    {:ok, %{"matches" => Memory.search(query, opts)}}
  end

  defp do_execute("remember_about_user", args, opts) do
    Memory.remember_user(args, opts)
  end

  defp do_execute("forget_about_user", args, opts) do
    Memory.forget_user(args, opts)
  end

  defp do_execute("list_user_memories", args, opts) do
    Memory.list_user(args, opts)
    |> memory_collection_result("memories")
  end

  defp do_execute("search_user_memory", args, opts) do
    Memory.search_user(args, opts)
    |> memory_collection_result("matches")
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
    Memory.recall_project(args, opts)
    |> memory_collection_result("memories")
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
        |> Map.put("child_ref", profile["id"])
        |> Map.put("target_agent_id", profile["id"])
        |> Map.put("target_skill", target_skill)
        |> Map.put("validation_contract", validation_contract)

      child_contract =
        Holt.Tasks.ChildAgentContract.build(%{
          "action" => "invoke_agent",
          "arguments" => invocation_args
        })

      {:ok,
       %{
         "schema_version" => "holt_agent_invocation/v1",
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
         "allowed_actions" => normalize_agent_list(args["allowed_actions"]),
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

  defp do_execute(_name, _args, _opts), do: {:error, :invalid_action_args}

  defp memory_collection_result(values, result_key) when is_list(values) do
    {:ok, %{result_key => values}}
  end

  defp memory_collection_result({:error, _reason} = error, _result_key), do: error

  defp agent_status(args) do
    status = optional_agent_text(args, "status")
    if status in [nil, "", "all"], do: nil, else: status
  end

  defp filter_agent_status(agents, nil), do: agents
  defp filter_agent_status(agents, status), do: Enum.filter(agents, &(&1["status"] == status))

  defp agent_identifier(args) when is_map(args) do
    case optional_agent_text(args, "agent_id") do
      nil -> {:error, :agent_id_required}
      agent_id -> {:ok, agent_id}
    end
  end

  defp agent_identifier(_args), do: {:error, :agent_id_required}

  defp repair_run_id(args) when is_map(args) do
    case optional_agent_text(args, "repair_run_id") do
      nil -> {:error, :repair_run_id_required}
      id -> {:ok, id}
    end
  end

  defp repair_run_id(_args), do: {:error, :repair_run_id_required}

  defp drop_agent_identifier_args(args) do
    Map.drop(args, [
      "agent_id",
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

  defp optional_agent_text(map, key, default),
    do: text(map, key, default)

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

  defp normalize_question_options(nil), do: {:ok, []}

  defp normalize_question_options(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn option, {:ok, options} ->
      case normalize_question_option(option) do
        {:ok, option} -> {:cont, {:ok, options ++ [option]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_question_options(_value), do: {:error, {:invalid_field, "options"}}

  defp normalize_question_option(option) when is_map(option) do
    with :ok <- canonical_map(option, "options[]"),
         {:ok, label} <- required_agent_text(option, "label"),
         {:ok, option_value} <- required_agent_text(option, "value") do
      {:ok,
       %{
         "label" => label,
         "value" => option_value,
         "description" => optional_agent_text(option, "description")
       }
       |> reject_empty()}
    end
  end

  defp normalize_question_option(_value), do: {:error, {:invalid_field, "options[]"}}

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp text(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      nil ->
        default

      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> default
          text -> text
        end

      _value ->
        default
    end
  end

  defp text(_map, _key, default), do: default

  defp canonical_map(map, field) do
    case canonical_value?(map) do
      true -> :ok
      false -> {:error, {:invalid_field, field}}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

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

  defp effective_risk(%{"name" => "read"} = action, %{"path" => path}, _opts) do
    if secret_path?(path), do: "secret", else: action["risk"]
  end

  defp effective_risk(action, _args, _opts), do: action["risk"]

  defp risk_requires_approval?("secret", _action), do: true
  defp risk_requires_approval?(_risk, %{"requires_approval" => value}), do: value == true

  defp default_reason(action) do
    "The agent requested #{action["name"]}."
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

  defp file_change_result(target, root, before, after_content, written_bytes \\ nil) do
    path = Path.relative_to(target, root)

    %{
      "path" => path,
      "bytes" => written_bytes(written_bytes, after_content)
    }
    |> Map.merge(FileDiff.summarize(path, before, after_content))
    |> reject_empty()
  end

  defp existing_text(nil), do: ""
  defp existing_text(content) when is_binary(content), do: content
  defp existing_text(_content), do: ""

  defp written_bytes(nil, after_content), do: byte_size(after_content)
  defp written_bytes(bytes, _after_content), do: bytes

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
    name in [".git", ".holt", ".holtworks", "_build", "deps", "node_modules"]
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

    cond do
      basename in secret_file_names() -> true
      Enum.any?(components, &(&1 in secret_directories())) -> true
      Path.extname(basename) in secret_extensions() -> true
      true -> false
    end
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
