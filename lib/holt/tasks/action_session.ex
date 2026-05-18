defmodule Holt.Tasks.ActionSession do
  @moduledoc """
  Local task-scoped action boundary for agent work.

  The session describes which actions are available for one task, which action groups
  are enabled, and which actions must be routed through policy metadata.
  """

  alias Holt.{Clock, LocalActions, Paths}

  @schema_version "holt_action_session/v1"
  @base_actionkits ~w(task memory agent_orchestration verification workspace)
  @unsupported_keys ~w(session task_graph_id)

  @task_actions ~w(
    list_tasks get_task create_task update_task set_priority set_estimate
    add_comment delete_comment todo_read todo_write
    add_label remove_label add_link remove_link
    list_task_specs get_task_spec save_task_spec read_task_memory_artifact
    save_teammate_memory load_teammate_runtime record_task_memory_artifact
    task_memory_context context_budget continuation_packet
    verifier_calibration
  )

  @orchestration_actions ~w(
    start_agent_work continue_agent_work delegate_to_agent invoke_agent watchdog_agent_runs
    schedule_mob_colleague_flow
    create_task_graph list_task_graphs get_task_graph advance_task_graph complete_task_graph_node
    work_graph_budget agent_dispatch_plan team_orchestration child_agent_contract
    verifier_dispatch
  )

  @verification_actions ~w(
    route_verification_review get_evidence_contract plan_verifier_route
    work_graph work_graph_gate work_graph_schedule
    verification_contract verifier_assignment
    action_contract plan_contract plan_gate action_preflight
    consequence_gate action_runtime_envelope complete_action_runtime_envelope
    capability_registry capability_contract capability_route generic_plan
    action_approval_request resolve_action_approval_request action_evidence_ledger
  )

  @meta_action_specs [
    %{
      "name" => "search_actions",
      "effect_scope" => "read_only",
      "purpose" => "Find available actions for the current task session."
    },
    %{
      "name" => "get_action_schema",
      "effect_scope" => "read_only",
      "purpose" => "Load action metadata before using an unfamiliar action."
    },
    %{
      "name" => "execute_action",
      "effect_scope" => "routed",
      "purpose" =>
        "Execute one read-only or session-ephemeral action through the task action router."
    },
    %{
      "name" => "multi_execute_action",
      "effect_scope" => "routed",
      "purpose" =>
        "Execute an ordered batch of read-only or session-ephemeral action calls through the router."
    },
    %{
      "name" => "manage_connection",
      "effect_scope" => "read_only",
      "purpose" => "Inspect locally declared connected-account context for this task session."
    },
    %{
      "name" => "use_workbench",
      "effect_scope" => "routed",
      "purpose" => "Inspect the local workbench or route a read-only workbench action."
    }
  ]

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_session(reason)
    end
  end

  def build(_attrs), do: rejected_session("invalid_attrs")

  def prompt_section(session) when is_map(session) do
    """
    ## Action Session
    Action session: #{session["session_id"]}
    Task scope: #{task_scope(session)}
    Policy profile: #{policy_profile_display(session)}
    Enabled action_groups: #{join_words(session["enabled_action_groups"])}
    Preloaded actions: #{join_words(session["preload_actions"])}
    Meta-actions: #{join_words(Enum.map(List.wrap(session["meta_actions"]), & &1["name"]))}

    Keep action use scoped to this task session. Route mutating actions through the task action router and leave durable completion decisions to structured verification.
    """
    |> String.trim()
  end

  def prompt_section(_session), do: nil

  def meta_action_names do
    Enum.map(@meta_action_specs, & &1["name"])
  end

  def direct_action_names do
    (@task_actions ++ @orchestration_actions ++ @verification_actions ++ LocalActions.names())
    |> Enum.uniq()
  end

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, task} <- optional_task(attrs),
         {:ok, ids} <- session_ids(attrs),
         {:ok, agent} <- agent_fields(attrs),
         {:ok, graph_id} <- optional_text(attrs, "graph_id", "invalid_graph_id"),
         {:ok, source} <- optional_text(attrs, "source", "invalid_source"),
         {:ok, profile} <- optional_text(attrs, "policy_profile", "invalid_policy_profile"),
         {:ok, enabled} <- enabled_groups(attrs),
         {:ok, disabled_groups} <- string_list_value(attrs, "disabled_action_groups"),
         {:ok, disabled_actions} <- string_list_value(attrs, "disabled_actions"),
         {:ok, direct_actions} <- string_list_value(attrs, "direct_actions"),
         {:ok, preload_actions} <- string_list_value(attrs, "preload_actions"),
         {:ok, connected_accounts} <-
           optional_map(attrs, "connected_accounts", "invalid_connected_accounts"),
         {:ok, todos} <- todos(attrs),
         {:ok, workbench} <- workbench(attrs, enabled, graph_id),
         {:ok, workspace} <- optional_text(attrs, "workspace", "invalid_workspace") do
      {:ok,
       %{
         task: task,
         ids: ids,
         agent: agent,
         graph_id: graph_id,
         source: source,
         policy_profile: profile,
         enabled_action_groups: enabled,
         disabled_action_groups: disabled_groups,
         disabled_actions: disabled_actions,
         direct_actions: direct_actions,
         preload_actions: preload_actions,
         connected_accounts: connected_accounts,
         todos: todos,
         workbench: workbench,
         workspace: workspace
       }}
    end
  end

  defp build_canonical(input) do
    task = input.task
    ids = input.ids
    agent = input.agent
    task_id = task["id"]
    task_ref = task["ref"]
    enabled = input.enabled_action_groups
    disabled_actions = input.disabled_actions
    direct_actions = direct_actions(enabled, disabled_actions, input.direct_actions)

    %{
      "schema_version" => @schema_version,
      "session_id" => session_id(ids["session_id"], task_id, task_ref, agent),
      "task_id" => task_id,
      "task_ref" => task_ref,
      "parent_task_id" => task["parent_id"],
      "agent_id" => agent["agent_id"],
      "agent_ref" => agent["agent_ref"],
      "agent_handle" => agent["agent_handle"],
      "agent_name" => agent["agent_name"],
      "run_id" => agent["run_id"],
      "agent_run_id" => agent["agent_run_id"],
      "graph_id" => input.graph_id,
      "source" => text_default(input.source, "action_session"),
      "policy_profile" => text_default(input.policy_profile, policy_profile(task_id)),
      "enabled_action_groups" => enabled,
      "disabled_action_groups" => input.disabled_action_groups,
      "disabled_actions" => disabled_actions,
      "connected_accounts" => input.connected_accounts,
      "todos" => input.todos,
      "workbench" => input.workbench,
      "preload_actions" => preload_actions(input.preload_actions),
      "meta_actions" => meta_actions(disabled_actions),
      "direct_actions" => direct_actions,
      "router" => %{
        "schema_version" => "holt_action_router/v1",
        "mode" => "session_scoped",
        "action_execution" => "policy_checked",
        "supports_meta_actions" => true
      },
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_session(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp optional_task(attrs) do
    case Map.fetch(attrs, "task") do
      {:ok, task} when is_map(task) ->
        with :ok <- validate_task(task) do
          {:ok, task}
        end

      {:ok, _task} ->
        {:error, "invalid_task"}

      :error ->
        {:ok, %{}}
    end
  end

  defp validate_task(task) do
    with :ok <- optional_text_field(task, "id", "invalid_task"),
         :ok <- optional_text_field(task, "ref", "invalid_task"),
         :ok <- optional_text_field(task, "parent_id", "invalid_task") do
      :ok
    end
  end

  defp session_ids(attrs) do
    with {:ok, session_id} <- optional_text(attrs, "session_id", "invalid_session_id") do
      {:ok, %{"session_id" => session_id}}
    end
  end

  defp agent_fields(attrs) do
    with {:ok, agent_id} <- optional_text(attrs, "agent_id", "invalid_agent_id"),
         {:ok, agent_ref} <- optional_text(attrs, "agent_ref", "invalid_agent_ref"),
         {:ok, agent_handle} <- optional_text(attrs, "agent_handle", "invalid_agent_handle"),
         {:ok, agent_name} <- optional_text(attrs, "agent_name", "invalid_agent_name"),
         {:ok, run_id} <- optional_text(attrs, "run_id", "invalid_run_id"),
         {:ok, agent_run_id} <- optional_text(attrs, "agent_run_id", "invalid_agent_run_id") do
      {:ok,
       %{
         "agent_id" => agent_id,
         "agent_ref" => agent_ref,
         "agent_handle" => agent_handle,
         "agent_name" => agent_name,
         "run_id" => run_id,
         "agent_run_id" => agent_run_id
       }}
    end
  end

  defp enabled_groups(attrs) do
    with {:ok, explicit} <- string_list_value(attrs, "enabled_action_groups"),
         {:ok, disabled} <- string_list_value(attrs, "disabled_action_groups") do
      disabled = MapSet.new(disabled)

      groups =
        (@base_actionkits ++ explicit)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(disabled, &1))

      {:ok, groups}
    end
  end

  defp direct_actions(enabled_action_groups, disabled_actions, explicit_actions) do
    disabled = MapSet.new(disabled_actions)

    [
      group_actions("task", @task_actions, enabled_action_groups),
      group_actions("memory", memory_actions(), enabled_action_groups),
      group_actions("agent_orchestration", @orchestration_actions, enabled_action_groups),
      group_actions("verification", @verification_actions, enabled_action_groups),
      group_actions("workspace", LocalActions.names(), enabled_action_groups),
      explicit_actions
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(disabled, &1))
  end

  defp group_actions(group, actions, enabled_action_groups) do
    case Enum.member?(enabled_action_groups, group) do
      true -> actions
      false -> []
    end
  end

  defp memory_actions do
    ~w(save_teammate_memory load_teammate_runtime read_task_memory_artifact recall remember remember_about_user forget_about_user list_user_memories search_user_memory remember_for_project save_plan save_research recall_project_memory read_project_memory)
  end

  defp workbench(attrs, enabled_action_groups, graph_id) do
    case Map.fetch(attrs, "workbench") do
      {:ok, workbench} when is_map(workbench) ->
        build_workbench(workbench, enabled_action_groups, attrs, graph_id)

      {:ok, _workbench} ->
        {:error, "invalid_workbench"}

      :error ->
        default_workbench(enabled_action_groups, attrs, graph_id)
    end
  end

  defp build_workbench(workbench, enabled_action_groups, attrs, graph_id) do
    with {:ok, enabled?} <- workbench_enabled(workbench, enabled_action_groups),
         {:ok, runtime} <- optional_text(workbench, "runtime", "invalid_workbench"),
         {:ok, workspace} <- optional_text(workbench, "workspace", "invalid_workbench"),
         :ok <- optional_text_field(workbench, "graph_id", "invalid_workbench") do
      {:ok,
       workbench
       |> Map.delete("enabled")
       |> Map.merge(%{
         "enabled" => enabled?,
         "runtime" => text_default(runtime, "workspace"),
         "workspace" => text_default(workspace, workspace(attrs)),
         "graph_id" => workbench_graph_id(workbench, graph_id)
       })
       |> compact()}
    end
  end

  defp default_workbench(enabled_action_groups, attrs, graph_id) do
    {:ok,
     %{
       "enabled" => Enum.member?(enabled_action_groups, "workspace"),
       "runtime" => "workspace",
       "workspace" => workspace(attrs),
       "graph_id" => graph_id
     }
     |> compact()}
  end

  defp workbench_enabled(workbench, enabled_action_groups) do
    case Map.fetch(workbench, "enabled") do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_workbench"}
      :error -> {:ok, Enum.member?(enabled_action_groups, "workspace")}
    end
  end

  defp workbench_graph_id(%{"graph_id" => graph_id}, _session_graph_id), do: graph_id
  defp workbench_graph_id(_workbench, session_graph_id), do: session_graph_id

  defp workspace(attrs) do
    case Map.fetch(attrs, "workspace") do
      {:ok, workspace} -> workspace
      :error -> Paths.workspace_root([])
    end
  end

  defp preload_actions([]) do
    ~w(search_actions get_action_schema execute_action get_task load_teammate_runtime todo_read)
  end

  defp preload_actions(actions), do: actions

  defp meta_actions(disabled_actions) do
    disabled = MapSet.new(disabled_actions)

    @meta_action_specs
    |> Enum.reject(&MapSet.member?(disabled, &1["name"]))
  end

  defp todos(attrs) do
    case Map.fetch(attrs, "todos") do
      {:ok, todos} when is_list(todos) ->
        normalize_todos(todos)

      {:ok, _todos} ->
        {:error, "invalid_todos"}

      :error ->
        {:ok, []}
    end
  end

  defp normalize_todos(todos) do
    Enum.reduce_while(todos, {:ok, []}, fn todo, {:ok, acc} ->
      case normalize_todo(todo) do
        {:ok, todo} -> {:cont, {:ok, acc ++ [todo]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_todo(todo) when is_map(todo) do
    with {:ok, content} <- required_text(todo, "content", "invalid_todos"),
         {:ok, status} <- todo_status(todo),
         {:ok, active_form} <- todo_active_form(todo, content) do
      {:ok,
       %{
         "content" => content,
         "status" => status,
         "activeForm" => active_form,
         "active_form" => active_form
       }}
    end
  end

  defp normalize_todo(_todo), do: {:error, "invalid_todos"}

  defp todo_status(todo) do
    case Map.fetch(todo, "status") do
      {:ok, value} when value in ["pending", "in_progress", "completed"] -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_todos"}
      :error -> {:ok, "pending"}
    end
  end

  defp todo_active_form(todo, content) do
    case Map.fetch(todo, "activeForm") do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "invalid_todos"}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, "invalid_todos"}

      :error ->
        active_form(todo, content)
    end
  end

  defp active_form(todo, content) do
    case Map.fetch(todo, "active_form") do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "invalid_todos"}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, "invalid_todos"}

      :error ->
        {:ok, content}
    end
  end

  defp session_id(session_id, task_id, task_ref, agent) do
    case session_id do
      nil -> generated_session_id(task_id, task_ref, agent)
      value -> value
    end
  end

  defp generated_session_id(nil, nil, _agent), do: "action_session:unscoped"

  defp generated_session_id(task_id, task_ref, agent) do
    [
      "action_session",
      session_task_ref(task_id, task_ref),
      agent["agent_id"],
      agent["run_id"]
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(":")
  end

  defp session_task_ref(_task_id, task_ref) when task_ref not in [nil, ""], do: task_ref
  defp session_task_ref(task_id, _task_ref), do: task_id

  defp policy_profile(nil), do: "interactive_agent"
  defp policy_profile(_task_id), do: "task_scoped_agent"

  defp join_words(nil), do: "none"
  defp join_words([]), do: "none"
  defp join_words(words), do: Enum.join(words, ", ")

  defp task_scope(%{"task_ref" => task_ref}) when task_ref not in [nil, ""], do: task_ref
  defp task_scope(%{"task_id" => task_id}) when task_id not in [nil, ""], do: task_id
  defp task_scope(_session), do: "none"

  defp policy_profile_display(%{"policy_profile" => policy}) when policy not in [nil, ""],
    do: policy

  defp policy_profile_display(_session), do: "interactive_agent"

  defp unsupported_arguments(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&unsupported_key?/1)
    |> unsupported_key_error()
  end

  defp unsupported_key?(key), do: key in @unsupported_keys

  defp unsupported_key_error(nil), do: :ok
  defp unsupported_key_error(key), do: {:error, "unsupported_argument:" <> key}

  defp canonical_attrs(attrs) do
    case canonical_value?(attrs) do
      true -> :ok
      false -> {:error, "invalid_attrs"}
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

  defp optional_map(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp string_list_value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, values} when is_list(values) ->
        validate_string_list(values, "invalid_" <> key)

      {:ok, _values} ->
        {:error, "invalid_" <> key}

      :error ->
        {:ok, []}
    end
  end

  defp validate_string_list(values, reason) do
    case Enum.all?(values, &nonempty_binary?/1) do
      true -> {:ok, values}
      false -> {:error, reason}
    end
  end

  defp required_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:error, reason}
    end
  end

  defp optional_text(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, nil}
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          _text -> :ok
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp text_default(nil, default), do: default
  defp text_default(value, _default), do: value

  defp nonempty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_binary?(_value), do: false

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(value), do: value in [nil, "", [], %{}]
end
