defmodule Holt.Tasks.PlanContract do
  @moduledoc """
  Active task plan contract for action authorization.

  A plan contract names the task scope, allowed effect scopes, allowed actions,
  and plan steps that can satisfy a gate before execution.
  """

  alias Holt.Clock
  alias Holt.Tasks.ActionContract

  @schema_version "holt_plan_contract/v1"
  @default_allowed_effect_scopes ~w(read_only session_ephemeral task_durable agent_orchestration routed)
  @workspace_effect_scopes ~w(workspace_durable external_side_effect)
  @unsupported_keys ~w(session task_graph task_graph_id task_id task_ref parent_task_id graph_id workspace)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_contract(reason)
    end
  end

  def build(_attrs), do: rejected_contract("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, task} <- task(attrs),
         {:ok, session} <- action_session(attrs),
         {:ok, plan_id} <- optional_text(attrs, "plan_id", "invalid_plan_id"),
         {:ok, status} <- optional_text(attrs, "status", "invalid_status"),
         {:ok, allow_workspace?} <- allow_workspace(attrs),
         {:ok, explicit_scopes} <- optional_string_list_value(attrs, "allowed_effect_scopes"),
         {:ok, explicit_actions} <- optional_string_list_value(attrs, "allowed_actions"),
         {:ok, explicit_steps} <- optional_plan_steps(attrs),
         {:ok, evidence_contract} <-
           optional_map(attrs, "evidence_contract", "invalid_evidence_contract"),
         {:ok, created_at} <- optional_text(attrs, "created_at", "invalid_created_at") do
      {:ok,
       %{
         task: task,
         action_session: session,
         plan_id: plan_id,
         status: status,
         allow_workspace?: allow_workspace?,
         explicit_scopes: explicit_scopes,
         explicit_actions: explicit_actions,
         explicit_steps: explicit_steps,
         evidence_contract: evidence_contract,
         created_at: created_at
       }}
    end
  end

  defp build_canonical(input) do
    task = input.task
    session = input.action_session
    allowed_effect_scopes = allowed_effect_scopes(input)
    allowed_actions = allowed_actions(input, session, allowed_effect_scopes)

    %{
      "schema_version" => @schema_version,
      "plan_id" => plan_id(input.plan_id),
      "status" => plan_status(input.status),
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "parent_task_id" => task["parent_id"],
      "graph_id" => session["graph_id"],
      "action_session_id" => session["session_id"],
      "policy_profile" => session["policy_profile"],
      "allowed_effect_scopes" => allowed_effect_scopes,
      "allowed_actions" => allowed_actions,
      "plan_steps" => plan_steps(input.explicit_steps, allowed_actions),
      "evidence_contract" => input.evidence_contract,
      "created_at" => created_at(input.created_at)
    }
    |> compact()
  end

  defp rejected_contract(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp task(attrs) do
    case Map.fetch(attrs, "task") do
      {:ok, task} when is_map(task) ->
        with :ok <- validate_task(task) do
          {:ok, task}
        end

      {:ok, _task} ->
        {:error, "invalid_task"}

      :error ->
        {:error, "missing_task"}
    end
  end

  defp validate_task(task) do
    with {:ok, _id} <- required_text(task, "id", "invalid_task"),
         {:ok, _ref} <- required_text(task, "ref", "invalid_task"),
         :ok <- optional_text_field(task, "parent_id", "invalid_task") do
      :ok
    end
  end

  defp action_session(attrs) do
    case Map.fetch(attrs, "action_session") do
      {:ok, session} when is_map(session) ->
        with :ok <- validate_session(session) do
          {:ok, session}
        end

      {:ok, _session} ->
        {:error, "invalid_action_session"}

      :error ->
        {:error, "missing_action_session"}
    end
  end

  defp validate_session(session) do
    with {:ok, _session_id} <- required_text(session, "session_id", "invalid_action_session"),
         :ok <- optional_text_field(session, "graph_id", "invalid_action_session"),
         :ok <- optional_text_field(session, "policy_profile", "invalid_action_session"),
         :ok <- optional_string_list(session, "direct_actions", "invalid_action_session"),
         :ok <- optional_meta_actions(session) do
      :ok
    end
  end

  defp optional_meta_actions(session) do
    case Map.fetch(session, "meta_actions") do
      {:ok, actions} when is_list(actions) ->
        validate_meta_actions(actions)

      {:ok, _actions} ->
        {:error, "invalid_action_session"}

      :error ->
        :ok
    end
  end

  defp validate_meta_actions(actions) do
    case Enum.all?(actions, &valid_meta_action?/1) do
      true -> :ok
      false -> {:error, "invalid_action_session"}
    end
  end

  defp valid_meta_action?(%{"name" => name}) when is_binary(name), do: String.trim(name) != ""
  defp valid_meta_action?(_action), do: false

  defp allow_workspace(attrs) do
    case Map.fetch(attrs, "allow_workspace_durable") do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_allow_workspace_durable"}
      :error -> {:ok, false}
    end
  end

  defp allowed_effect_scopes(%{explicit_scopes: scopes}) when scopes != [], do: scopes

  defp allowed_effect_scopes(%{allow_workspace?: true}) do
    @default_allowed_effect_scopes ++ @workspace_effect_scopes
  end

  defp allowed_effect_scopes(_input), do: @default_allowed_effect_scopes

  defp allowed_actions(%{explicit_actions: actions}, _session, scopes) when actions != [] do
    actions
    |> Enum.uniq()
    |> Enum.filter(&(ActionContract.effect_scope(&1) in scopes))
  end

  defp allowed_actions(_input, session, scopes) do
    session
    |> session_action_names()
    |> Enum.uniq()
    |> Enum.filter(&(ActionContract.effect_scope(&1) in scopes))
  end

  defp session_action_names(session) do
    direct_action_names(session) ++ meta_action_names(session)
  end

  defp plan_steps([], allowed_actions), do: default_plan_steps(allowed_actions)
  defp plan_steps(steps, _allowed_actions), do: steps

  defp default_plan_steps(allowed_actions) do
    [
      step("read_context", "read_only", allowed_actions),
      step("update_session_state", "session_ephemeral", allowed_actions),
      step("update_task_state", "task_durable", allowed_actions),
      step("orchestrate_agent_work", "agent_orchestration", allowed_actions),
      step("routed_meta_action", "routed", allowed_actions),
      step("workspace_effect", "workspace_durable", allowed_actions),
      step("external_effect", "external_side_effect", allowed_actions)
    ]
    |> Enum.reject(&(&1["allowed_actions"] == []))
  end

  defp step(step_id, effect_scope, allowed_actions) do
    %{
      "step_id" => step_id,
      "effect_scope" => effect_scope,
      "allowed_actions" =>
        Enum.filter(allowed_actions, &(ActionContract.effect_scope(&1) == effect_scope))
    }
  end

  defp optional_plan_steps(attrs) do
    case Map.fetch(attrs, "plan_steps") do
      {:ok, steps} when is_list(steps) -> validate_plan_steps(steps)
      {:ok, _steps} -> {:error, "invalid_plan_steps"}
      :error -> {:ok, []}
    end
  end

  defp validate_plan_steps(steps) do
    case Enum.all?(steps, &valid_step?/1) do
      true -> {:ok, steps}
      false -> {:error, "invalid_plan_steps"}
    end
  end

  defp valid_step?(step) when is_map(step) do
    with {:ok, _step_id} <- required_text(step, "step_id", "invalid_plan_steps"),
         {:ok, _scope} <- required_text(step, "effect_scope", "invalid_plan_steps"),
         :ok <- optional_string_list(step, "allowed_actions", "invalid_plan_steps") do
      true
    else
      _error -> false
    end
  end

  defp valid_step?(_step), do: false

  defp meta_action_names(session) do
    session
    |> Map.get("meta_actions", [])
    |> Enum.map(& &1["name"])
  end

  defp direct_action_names(session) do
    case Map.fetch(session, "direct_actions") do
      {:ok, actions} -> actions
      :error -> []
    end
  end

  defp plan_id(nil), do: Clock.id("plan_contract")
  defp plan_id(value), do: value

  defp plan_status(nil), do: "active"
  defp plan_status(value), do: value

  defp created_at(nil), do: Clock.iso_now()
  defp created_at(value), do: value

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

  defp optional_string_list_value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, values} when is_list(values) ->
        case validate_string_list(values, "invalid_" <> key) do
          :ok -> {:ok, values}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _values} ->
        {:error, "invalid_" <> key}

      :error ->
        {:ok, []}
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        validate_string_list(values, reason)

      {:ok, _values} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp validate_string_list(values, reason) do
    case Enum.all?(values, &nonempty_binary?/1) do
      true -> :ok
      false -> {:error, reason}
    end
  end

  defp optional_map(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
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

  defp nonempty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_binary?(_value), do: false

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
