defmodule Holt.Tasks.ActionRouter do
  @moduledoc """
  Session-scoped route metadata for local task action calls.

  The router produces the structured route and action contract that execution
  providers and later gates evaluate before dispatch.
  """

  alias Holt.Clock
  alias Holt.Tasks.{ActionContract, ActionSession}

  @schema_version "holt_action_route/v1"

  def route(attrs \\ %{})

  def route(attrs) when is_map(attrs) do
    with {:ok, input} <- input(attrs),
         {:ok, status_reason} <- route_status(input.action, input.session) do
      session = input.session
      action = input.action

      action_contract =
        ActionContract.build(
          attrs
          |> Map.put("action", contract_action(action))
          |> Map.put("arguments", input.arguments)
          |> Map.put("action_session", session)
        )

      %{
        "schema_version" => @schema_version,
        "route_id" => Clock.id("action_route"),
        "status" => elem(status_reason, 0),
        "reason" => elem(status_reason, 1),
        "action" => action,
        "action_call_id" => input.action_call_id,
        "route_kind" => route_kind(action, session),
        "action_session_id" => session["session_id"],
        "task_id" => session["task_id"],
        "task_ref" => session["task_ref"],
        "agent_id" => session["agent_id"],
        "policy_profile" => session["policy_profile"],
        "enabled_action_groups" => session["enabled_action_groups"],
        "workbench" => session["workbench"],
        "requires_approval" => ActionContract.requires_approval?(action_contract),
        "action_contract" => action_contract,
        "created_at" => Clock.iso_now()
      }
      |> compact()
    else
      {:error, reason} -> rejected_route(reason)
    end
  end

  def route(_attrs), do: rejected_route("invalid_attrs")

  def route(action, arguments, session) do
    route(%{"action" => action, "arguments" => arguments, "action_session" => session})
  end

  def allowed?(action, session) do
    with {:ok, action} <- action_name(%{"action" => action}),
         {:ok, session} <- action_session(%{"action_session" => session}),
         {:ok, {"accepted", _reason}} <- route_status(action, session) do
      true
    else
      _error -> false
    end
  end

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, action} <- action_name(attrs),
         {:ok, arguments} <- arguments(attrs),
         {:ok, action_call_id} <- optional_text(attrs, "action_call_id", "invalid_action_call_id"),
         {:ok, session} <- action_session(attrs) do
      {:ok,
       %{
         action: action,
         arguments: arguments,
         action_call_id: action_call_id,
         session: session
       }}
    end
  end

  defp action_session(attrs) do
    case Map.fetch(attrs, "action_session") do
      {:ok, session} when is_map(session) -> build_session(session)
      {:ok, _session} -> {:error, "invalid_action_session"}
      :error -> build_session(attrs)
    end
  end

  defp build_session(attrs) do
    case ActionSession.build(attrs) do
      %{"status" => "rejected", "reason" => reason} -> {:error, reason}
      session when is_map(session) -> {:ok, session}
    end
  end

  defp contract_action(nil), do: "unknown"
  defp contract_action(""), do: "unknown"
  defp contract_action(action), do: action

  defp route_status(nil, _session), do: {:ok, {"rejected", "action_required"}}

  defp route_status(action_name, session) do
    with {:ok, disabled_actions} <- string_list(session, "disabled_actions"),
         {:ok, direct_actions} <- string_list(session, "direct_actions"),
         {:ok, meta_actions} <- meta_action_names(session) do
      disabled = MapSet.new(disabled_actions)

      cond do
        MapSet.member?(disabled, action_name) ->
          {:ok, {"rejected", "action_disabled_for_session"}}

        action_name in meta_actions ->
          {:ok, {"accepted", "meta_action_allowed"}}

        action_name in direct_actions ->
          {:ok, {"accepted", "direct_action_allowed"}}

        true ->
          {:ok, {"rejected", "action_not_declared_for_session"}}
      end
    end
  end

  defp route_kind(nil, _session), do: nil

  defp route_kind(action_name, session) do
    with {:ok, direct_actions} <- string_list(session, "direct_actions"),
         {:ok, meta_actions} <- meta_action_names(session) do
      cond do
        action_name in meta_actions -> "meta"
        action_name in direct_actions -> "direct"
        true -> "unavailable"
      end
    else
      _error -> "unavailable"
    end
  end

  defp meta_action_names(session) do
    case Map.fetch(session, "meta_actions") do
      {:ok, actions} when is_list(actions) ->
        Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, names} ->
          case meta_action_name(action) do
            {:ok, name} -> {:cont, {:ok, [name | names]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> reverse_names()

      {:ok, _actions} ->
        {:error, "invalid_meta_actions"}

      :error ->
        {:ok, []}
    end
  end

  defp meta_action_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, "invalid_meta_actions"}
      text -> {:ok, text}
    end
  end

  defp meta_action_name(_action), do: {:error, "invalid_meta_actions"}

  defp reverse_names({:ok, names}), do: {:ok, Enum.reverse(names)}
  defp reverse_names({:error, reason}), do: {:error, reason}

  defp action_name(attrs) do
    case Map.fetch(attrs, "action") do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, nil}
          action -> {:ok, action}
        end

      {:ok, nil} ->
        {:ok, nil}

      {:ok, _value} ->
        {:error, "invalid_action"}

      :error ->
        {:ok, nil}
    end
  end

  defp arguments(attrs) do
    case Map.fetch(attrs, "arguments") do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_arguments"}
      :error -> {:ok, %{}}
    end
  end

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

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp optional_text(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, nil}
          text -> {:ok, text}
        end

      {:ok, nil} ->
        {:ok, nil}

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, nil}
    end
  end

  defp string_list(session, key) do
    case Map.fetch(session, key) do
      {:ok, values} when is_list(values) -> validate_string_list(values, "invalid_" <> key)
      {:ok, _values} -> {:error, "invalid_" <> key}
      :error -> {:ok, []}
    end
  end

  defp validate_string_list(values, reason) do
    case Enum.all?(values, &nonempty_binary?/1) do
      true -> {:ok, values}
      false -> {:error, reason}
    end
  end

  defp nonempty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_binary?(_value), do: false

  defp rejected_route(reason) do
    %{
      "schema_version" => @schema_version,
      "route_id" => Clock.id("action_route"),
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(value), do: value in [nil, "", [], %{}]
end
