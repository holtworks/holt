defmodule Holt.Tasks.TaskToolSession do
  @moduledoc """
  Local task-scoped tool boundary for agent work.

  The session describes which tools are available for one task, which toolkits
  are enabled, and which tools must be routed through policy metadata.
  """

  alias Holt.{Clock, Paths, Tools}

  @schema_version "holtworks_task_tool_session/v1"
  @base_toolkits ~w(task memory agent_orchestration verification workspace)

  @task_tools ~w(
    list_tasks get_task create_task update_task set_priority set_estimate
    add_comment delete_comment todo_read todo_write
    add_label remove_label add_link remove_link
    list_task_specs get_task_spec save_task_spec read_task_memory_artifact
    save_teammate_memory load_teammate_runtime record_task_memory_artifact
    task_memory_context context_budget continuation_packet
    verifier_calibration
  )

  @orchestration_tools ~w(
    start_agent_work continue_agent_work watchdog_agent_runs
    create_task_graph list_task_graphs get_task_graph advance_task_graph complete_task_graph_node
    work_graph_budget agent_dispatch_plan team_orchestration child_agent_contract
    verifier_dispatch
  )

  @verification_tools ~w(
    route_verification_review get_evidence_contract plan_verifier_route
    work_graph work_graph_gate work_graph_schedule
    verification_contract verifier_assignment
    action_contract plan_contract plan_gate action_preflight
    consequence_gate action_runtime_envelope complete_action_runtime_envelope
    capability_registry capability_contract capability_route generic_plan
    action_approval_request resolve_action_approval_request action_evidence_ledger
  )

  @meta_tool_specs [
    %{
      "name" => "search_tools",
      "effect_scope" => "read_only",
      "purpose" => "Find available tools for the current task session."
    },
    %{
      "name" => "get_tool_schema",
      "effect_scope" => "read_only",
      "purpose" => "Load tool metadata before using an unfamiliar tool."
    },
    %{
      "name" => "execute_tool",
      "effect_scope" => "routed",
      "purpose" => "Execute one read-only or session-ephemeral tool through the task tool router."
    },
    %{
      "name" => "multi_execute_tool",
      "effect_scope" => "routed",
      "purpose" =>
        "Execute an ordered batch of read-only or session-ephemeral tool calls through the router."
    },
    %{
      "name" => "manage_connection",
      "effect_scope" => "read_only",
      "purpose" => "Inspect locally declared connected-account context for this task session."
    },
    %{
      "name" => "use_workbench",
      "effect_scope" => "routed",
      "purpose" => "Inspect the local workbench or route a read-only workbench tool."
    }
  ]

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    task = normalize_map(value(attrs, "task"))
    task_id = value(task, "id") || optional_text(attrs, "task_id")
    task_ref = value(task, "ref") || optional_text(attrs, "task_ref")
    session_id = optional_text(attrs, "session_id") || session_id(task_id, task_ref, attrs)
    enabled_toolkits = enabled_toolkits(attrs)
    disabled_tools = normalize_string_list(value(attrs, "disabled_tools"))
    direct_tools = direct_tools(attrs, enabled_toolkits, disabled_tools)

    %{
      "schema_version" => @schema_version,
      "session_id" => session_id,
      "task_id" => task_id,
      "task_ref" => task_ref,
      "parent_task_id" => value(task, "parent_id") || optional_text(attrs, "parent_task_id"),
      "agent_id" => optional_text(attrs, "agent_id"),
      "agent_ref" => optional_text(attrs, "agent_ref"),
      "agent_handle" => optional_text(attrs, "agent_handle"),
      "agent_name" => optional_text(attrs, "agent_name"),
      "run_id" => optional_text(attrs, "run_id"),
      "agent_run_id" => optional_text(attrs, "agent_run_id"),
      "graph_id" => optional_text(attrs, "graph_id", optional_text(attrs, "task_graph_id")),
      "source" => optional_text(attrs, "source", "task_tool_session"),
      "policy_profile" => optional_text(attrs, "policy_profile", policy_profile(task_id)),
      "enabled_toolkits" => enabled_toolkits,
      "disabled_toolkits" => normalize_string_list(value(attrs, "disabled_toolkits")),
      "disabled_tools" => disabled_tools,
      "connected_accounts" => connected_accounts(attrs),
      "todos" => normalize_todos(value(attrs, "todos")),
      "workbench" => workbench(attrs, enabled_toolkits),
      "preload_tools" => preload_tools(attrs),
      "meta_tools" => meta_tools(attrs),
      "direct_tools" => direct_tools,
      "router" => %{
        "schema_version" => "holtworks_task_tool_router/v1",
        "mode" => "session_scoped",
        "tool_execution" => "policy_checked",
        "supports_meta_tools" => true
      },
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  def build(_attrs), do: build(%{})

  def prompt_section(session) when is_map(session) do
    """
    ## Task Tool Session
    Tool session: #{session["session_id"]}
    Task scope: #{session["task_ref"] || session["task_id"] || "none"}
    Policy profile: #{session["policy_profile"] || "interactive_agent"}
    Enabled toolkits: #{join_words(session["enabled_toolkits"])}
    Preloaded tools: #{join_words(session["preload_tools"])}
    Meta-tools: #{join_words(Enum.map(session["meta_tools"] || [], & &1["name"]))}

    Keep tool use scoped to this task session. Route mutating actions through the task tool router and leave durable completion decisions to structured verification.
    """
    |> String.trim()
  end

  def prompt_section(_session), do: nil

  def meta_tool_names do
    Enum.map(@meta_tool_specs, & &1["name"])
  end

  def direct_tool_names do
    (@task_tools ++ @orchestration_tools ++ @verification_tools ++ Tools.names())
    |> Enum.uniq()
  end

  defp session_id(nil, nil, _attrs), do: "task_tool_session:unscoped"

  defp session_id(task_id, task_ref, attrs) do
    [
      "task_tool_session",
      task_ref || task_id,
      optional_text(attrs, "agent_id"),
      optional_text(attrs, "run_id")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(":")
  end

  defp enabled_toolkits(attrs) do
    explicit = normalize_string_list(value(attrs, "enabled_toolkits"))
    disabled = MapSet.new(normalize_string_list(value(attrs, "disabled_toolkits")))

    (@base_toolkits ++ explicit)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(disabled, &1))
  end

  defp direct_tools(attrs, enabled_toolkits, disabled_tools) do
    disabled = MapSet.new(disabled_tools)

    [
      if("task" in enabled_toolkits, do: @task_tools, else: []),
      if("memory" in enabled_toolkits,
        do:
          ~w(save_teammate_memory load_teammate_runtime read_task_memory_artifact search_memory save_memory remember_about_user forget_about_user list_user_memories search_user_memory remember_for_project save_plan save_research recall_project_memory read_project_memory),
        else: []
      ),
      if("agent_orchestration" in enabled_toolkits, do: @orchestration_tools, else: []),
      if("verification" in enabled_toolkits, do: @verification_tools, else: []),
      if("workspace" in enabled_toolkits, do: Tools.names(), else: []),
      normalize_string_list(value(attrs, "direct_tools"))
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(disabled, &1))
  end

  defp connected_accounts(attrs) do
    attrs
    |> value("connected_accounts")
    |> normalize_map()
  end

  defp workbench(attrs, enabled_toolkits) do
    explicit = normalize_map(value(attrs, "workbench"))
    explicit_enabled = value(explicit, "enabled")

    enabled? =
      if is_nil(explicit_enabled) do
        "workspace" in enabled_toolkits
      else
        truthy?(explicit_enabled)
      end

    %{
      "enabled" => enabled?,
      "runtime" => optional_text(explicit, "runtime", "workspace"),
      "workspace" => optional_text(attrs, "workspace", Paths.workspace_root([])),
      "graph_id" => optional_text(attrs, "graph_id", optional_text(attrs, "task_graph_id"))
    }
    |> Map.merge(explicit)
    |> reject_empty()
  end

  defp preload_tools(attrs) do
    attrs
    |> value("preload_tools")
    |> normalize_string_list()
    |> case do
      [] -> ~w(search_tools get_tool_schema execute_tool get_task load_teammate_runtime todo_read)
      tools -> tools
    end
  end

  defp meta_tools(attrs) do
    disabled = MapSet.new(normalize_string_list(value(attrs, "disabled_tools")))

    @meta_tool_specs
    |> Enum.reject(&MapSet.member?(disabled, &1["name"]))
  end

  defp policy_profile(nil), do: "interactive_agent"
  defp policy_profile(_task_id), do: "task_scoped_agent"

  defp join_words(nil), do: "none"
  defp join_words([]), do: "none"
  defp join_words(words), do: Enum.join(words, ", ")

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    text = value |> to_string() |> String.trim()

    if text == "" do
      []
    else
      text
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp normalize_todos(value) when is_list(value) do
    value
    |> Enum.map(&normalize_todo/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_todos(_value), do: []

  defp normalize_todo(value) when is_map(value) do
    todo = string_keys(value)
    content = optional_text(todo, "content")

    if content in [nil, ""] do
      %{}
    else
      active_form =
        optional_text(todo, "activeForm", optional_text(todo, "active_form", content))

      %{
        "content" => content,
        "status" => todo_status(optional_text(todo, "status", "pending")),
        "activeForm" => active_form,
        "active_form" => active_form
      }
      |> reject_empty()
    end
  end

  defp normalize_todo(value) do
    content = value |> to_string() |> String.trim()

    if content == "" do
      %{}
    else
      %{
        "content" => content,
        "status" => "pending",
        "activeForm" => content,
        "active_form" => content
      }
    end
  end

  defp todo_status(status) when status in ["pending", "in_progress", "completed"], do: status
  defp todo_status(_status), do: "pending"

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp optional_text(attrs, key, default \\ nil)

  defp optional_text(attrs, key, default) when is_map(attrs) do
    case Map.get(attrs, key, default) do
      nil ->
        default

      value ->
        text = value |> to_string() |> String.trim()
        if text == "", do: default, else: text
    end
  end

  defp optional_text(_attrs, _key, default), do: default

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp string_keys(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: string_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
