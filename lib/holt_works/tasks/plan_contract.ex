defmodule HoltWorks.Tasks.PlanContract do
  @moduledoc """
  Active task plan contract for tool authorization.

  A plan contract names the task scope, allowed effect scopes, allowed tools, and
  plan steps that can satisfy a gate before execution.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.{ActionContract, TaskToolSession}

  @schema_version "holtworks_plan_contract/v1"
  @default_allowed_effect_scopes ~w(read_only session_ephemeral task_durable agent_orchestration routed)
  @workspace_effect_scopes ~w(workspace_durable external_side_effect)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    task = normalize_map(value(attrs, "task"))
    session = task_tool_session(attrs)
    allowed_effect_scopes = allowed_effect_scopes(attrs)
    allowed_tools = allowed_tools(attrs, session, allowed_effect_scopes)
    task_id = value(task, "id") || session["task_id"] || optional_text(attrs, "task_id")
    task_ref = value(task, "ref") || session["task_ref"] || optional_text(attrs, "task_ref")

    %{
      "schema_version" => @schema_version,
      "plan_id" => optional_text(attrs, "plan_id", Clock.id("plan_contract")),
      "status" => optional_text(attrs, "status", "active"),
      "task_id" => task_id,
      "task_ref" => task_ref,
      "parent_task_id" =>
        value(task, "parent_id") || session["parent_task_id"] ||
          optional_text(attrs, "parent_task_id"),
      "graph_id" => graph_id(attrs, session),
      "tool_session_id" => session["session_id"],
      "policy_profile" => session["policy_profile"],
      "allowed_effect_scopes" => allowed_effect_scopes,
      "allowed_tools" => allowed_tools,
      "plan_steps" => plan_steps(attrs, allowed_tools),
      "evidence_contract" => normalize_map(value(attrs, "evidence_contract")),
      "created_at" => optional_text(attrs, "created_at", Clock.iso_now())
    }
    |> reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp task_tool_session(attrs) do
    case value(attrs, "task_tool_session") || value(attrs, "session") do
      session when is_map(session) -> TaskToolSession.build(session)
      _missing -> TaskToolSession.build(attrs)
    end
  end

  defp allowed_effect_scopes(attrs) do
    explicit = normalize_string_list(value(attrs, "allowed_effect_scopes"))

    cond do
      explicit != [] ->
        explicit

      value(attrs, "allow_workspace_durable") == true ->
        @default_allowed_effect_scopes ++ @workspace_effect_scopes

      true ->
        @default_allowed_effect_scopes
    end
  end

  defp allowed_tools(attrs, session, allowed_effect_scopes) do
    explicit = normalize_string_list(value(attrs, "allowed_tools"))

    source =
      if explicit == [] do
        direct_tool_names(session) ++ meta_tool_names(session)
      else
        explicit
      end

    source
    |> Enum.uniq()
    |> Enum.filter(&(ActionContract.effect_scope(&1) in allowed_effect_scopes))
  end

  defp plan_steps(attrs, allowed_tools) do
    explicit = normalize_step_list(value(attrs, "plan_steps"))

    if explicit == [] do
      default_plan_steps(allowed_tools)
    else
      explicit
    end
  end

  defp default_plan_steps(allowed_tools) do
    [
      step("read_context", "read_only", allowed_tools),
      step("update_session_state", "session_ephemeral", allowed_tools),
      step("update_task_state", "task_durable", allowed_tools),
      step("orchestrate_agent_work", "agent_orchestration", allowed_tools),
      step("routed_meta_tool", "routed", allowed_tools),
      step("workspace_effect", "workspace_durable", allowed_tools),
      step("external_effect", "external_side_effect", allowed_tools)
    ]
    |> Enum.reject(&(Map.get(&1, "allowed_tools") == []))
  end

  defp step(step_id, effect_scope, allowed_tools) do
    %{
      "step_id" => step_id,
      "effect_scope" => effect_scope,
      "allowed_tools" =>
        Enum.filter(allowed_tools, &(ActionContract.effect_scope(&1) == effect_scope))
    }
  end

  defp normalize_step_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_map/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_step_list(_value), do: []

  defp graph_id(attrs, session) do
    graph = normalize_map(value(attrs, "task_graph"))

    value(graph, "id") ||
      optional_text(attrs, "graph_id", optional_text(attrs, "task_graph_id", session["graph_id"]))
  end

  defp meta_tool_names(session) do
    session
    |> Map.get("meta_tools", [])
    |> Enum.map(fn
      %{"name" => name} -> name
      _tool -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp direct_tool_names(session), do: normalize_string_list(session["direct_tools"])

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
