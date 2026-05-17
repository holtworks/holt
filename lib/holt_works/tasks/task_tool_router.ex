defmodule HoltWorks.Tasks.TaskToolRouter do
  @moduledoc """
  Session-scoped route metadata for local task tool calls.

  The router produces the structured route and action contract that execution
  providers and later gates evaluate before dispatch.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.{ActionContract, TaskToolSession}

  @schema_version "holtworks_task_tool_route/v1"

  def route(attrs \\ %{})

  def route(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    session = task_tool_session(attrs)
    tool_name = optional_text(attrs, "tool_name")
    arguments = normalize_map(value(attrs, "arguments"))
    status_reason = route_status(tool_name, session)

    action_contract =
      ActionContract.build(
        attrs
        |> Map.put("tool_name", tool_name || "unknown")
        |> Map.put("arguments", arguments)
        |> Map.put("task_tool_session", session)
      )

    %{
      "schema_version" => @schema_version,
      "route_id" => Clock.id("task_tool_route"),
      "status" => elem(status_reason, 0),
      "reason" => elem(status_reason, 1),
      "tool_name" => tool_name,
      "tool_call_id" => optional_text(attrs, "tool_call_id"),
      "route_kind" => route_kind(tool_name, session),
      "tool_session_id" => session["session_id"],
      "task_id" => session["task_id"],
      "task_ref" => session["task_ref"],
      "agent_id" => session["agent_id"],
      "policy_profile" => session["policy_profile"],
      "enabled_toolkits" => session["enabled_toolkits"],
      "workbench" => session["workbench"],
      "requires_approval" => ActionContract.requires_approval?(action_contract),
      "action_contract" => action_contract,
      "created_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  def route(_attrs), do: route(%{})

  def route(tool_name, arguments, session) do
    route(%{"tool_name" => tool_name, "arguments" => arguments, "task_tool_session" => session})
  end

  def allowed?(tool_name, session) do
    case route_status(
           normalize_tool_name(tool_name),
           task_tool_session(%{"task_tool_session" => session})
         ) do
      {"accepted", _reason} -> true
      _other -> false
    end
  end

  defp task_tool_session(attrs) do
    case value(attrs, "task_tool_session") || value(attrs, "session") do
      session when is_map(session) -> TaskToolSession.build(session)
      _missing -> TaskToolSession.build(attrs)
    end
  end

  defp route_status(nil, _session), do: {"rejected", "tool_name_required"}

  defp route_status(tool_name, session) do
    disabled = MapSet.new(normalize_string_list(session["disabled_tools"]))

    cond do
      MapSet.member?(disabled, tool_name) ->
        {"rejected", "tool_disabled_for_session"}

      tool_name in meta_tool_names(session) ->
        {"accepted", "meta_tool_allowed"}

      tool_name in direct_tool_names(session) ->
        {"accepted", "direct_tool_allowed"}

      true ->
        {"rejected", "tool_not_declared_for_session"}
    end
  end

  defp route_kind(nil, _session), do: nil

  defp route_kind(tool_name, session) do
    cond do
      tool_name in meta_tool_names(session) -> "meta"
      tool_name in direct_tool_names(session) -> "direct"
      true -> "unavailable"
    end
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

  defp normalize_tool_name(nil), do: nil

  defp normalize_tool_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      tool_name -> tool_name
    end
  end

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    text = value |> to_string() |> String.trim()
    if text == "", do: [], else: [text]
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
