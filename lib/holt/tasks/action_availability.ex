defmodule Holt.Tasks.ActionAvailability do
  @moduledoc """
  Structured availability snapshot for actions used by task-agent runs.

  This contract reports whether a action is available from explicit runtime
  fields. It does not infer availability from task prose.
  """

  alias Holt.Clock
  alias Holt.Tasks.{ActionContract, ActionSession}

  @schema_version "holt_action_availability/v1"
  @workspace_statuses ~w(ready missing)
  @network_statuses ~w(enabled disabled)
  @approval_statuses ~w(approved denied required not_required)

  def snapshot(attrs \\ %{})

  def snapshot(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, action_names} <- action_names(attrs),
         :ok <- validate_enum(attrs, "workspace_status", @workspace_statuses),
         :ok <- validate_enum(attrs, "network_status", @network_statuses),
         :ok <- validate_enum(attrs, "approval_status", @approval_statuses) do
      Enum.map(action_names, &availability_record(&1, attrs))
    else
      {:error, reason} -> [rejected_record(reason)]
    end
  end

  def snapshot(_attrs), do: [rejected_record("invalid_attrs")]

  defp rejected_record(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  def availability_for(action_availability, action_name) when is_list(action_availability) do
    Enum.find(action_availability, fn
      %{"name" => ^action_name} -> true
      _entry -> false
    end)
  end

  def availability_for(_action_availability, _action_name), do: nil

  def available?(action_availability, action_name) do
    case availability_for(action_availability, action_name) do
      %{"available" => true} -> true
      _entry -> false
    end
  end

  defp availability_record(action_name, attrs) do
    effect_scope = ActionContract.effect_scope(action_name)
    unavailable_reason = unavailable_reason(action_name, effect_scope, attrs)

    %{
      "schema_version" => @schema_version,
      "name" => action_name,
      "category" => category(action_name, effect_scope),
      "effect_scope" => effect_scope,
      "required_permission" => required_permission(effect_scope),
      "required_capability" => required_capability(action_name, effect_scope),
      "requires_workspace" => requires_workspace?(effect_scope),
      "requires_network" => effect_scope == "external_side_effect",
      "requires_approval" =>
        ActionContract.requires_approval?(%{"effect_scope" => effect_scope, "risk_level" => nil}),
      "available" => is_nil(unavailable_reason),
      "unavailable_reason" => unavailable_reason,
      "retryable" => retryable?(unavailable_reason),
      "checked_at" => Clock.iso_now()
    }
    |> reject_empty()
  end

  defp unavailable_reason(_action_name, effect_scope, attrs) do
    cond do
      effect_scope == "unknown" ->
        "action_not_registered"

      requires_workspace?(effect_scope) and workspace_missing?(attrs) ->
        "workspace_required"

      effect_scope == "external_side_effect" and network_disabled?(attrs) ->
        "network_disabled"

      approval_blocked?(effect_scope, attrs) ->
        "approval_required"

      true ->
        nil
    end
  end

  defp workspace_missing?(attrs) do
    Map.get(attrs, "workspace_status") == "missing"
  end

  defp network_disabled?(attrs) do
    Map.get(attrs, "network_status") == "disabled"
  end

  defp approval_blocked?(effect_scope, attrs) do
    effect_scope in ["workspace_durable", "external_side_effect"] and
      Map.get(attrs, "approval_status") == "denied"
  end

  defp retryable?("workspace_required"), do: true
  defp retryable?("approval_required"), do: false
  defp retryable?("network_disabled"), do: false
  defp retryable?("action_not_registered"), do: false
  defp retryable?(_reason), do: false

  defp requires_workspace?(effect_scope) do
    effect_scope in [
      "read_only",
      "session_ephemeral",
      "task_durable",
      "agent_orchestration",
      "workspace_durable"
    ]
  end

  defp category(_action_name, "read_only"), do: "read"
  defp category(_action_name, "session_ephemeral"), do: "session"
  defp category(_action_name, "task_durable"), do: "task"
  defp category(_action_name, "agent_orchestration"), do: "agent_orchestration"
  defp category(_action_name, "workspace_durable"), do: "workspace"
  defp category(_action_name, "external_side_effect"), do: "external"
  defp category(_action_name, "routed"), do: "router"
  defp category(_action_name, _effect_scope), do: "unknown"

  defp required_permission("read_only"), do: "task_read"
  defp required_permission("session_ephemeral"), do: "session_write"
  defp required_permission("task_durable"), do: "task_write"
  defp required_permission("agent_orchestration"), do: "agent_orchestration"
  defp required_permission("workspace_durable"), do: "workspace_write"
  defp required_permission("external_side_effect"), do: "external_side_effect"
  defp required_permission("routed"), do: "action_route"
  defp required_permission(_effect_scope), do: "unknown"

  defp required_capability("route_verification_review", _effect_scope), do: "verification_review"
  defp required_capability(_action_name, "read_only"), do: "assigned_task_context"
  defp required_capability(_action_name, "session_ephemeral"), do: "session_state_update"
  defp required_capability(_action_name, "task_durable"), do: "task_state_update"
  defp required_capability(_action_name, "agent_orchestration"), do: "agent_work_orchestration"
  defp required_capability(_action_name, "workspace_durable"), do: "workspace_mutation"
  defp required_capability(_action_name, "external_side_effect"), do: "external_operation"
  defp required_capability(_action_name, "routed"), do: "action_routing"
  defp required_capability(_action_name, _effect_scope), do: "unknown"

  defp action_names(attrs) do
    case optional_string_list(attrs, "action_names") do
      {:ok, []} ->
        {:ok,
         ActionSession.direct_action_names()
         |> Kernel.++(ActionSession.meta_action_names())
         |> Enum.uniq()
         |> Enum.sort()}

      {:ok, names} ->
        {:ok, names |> Enum.uniq() |> Enum.sort()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp optional_string_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> string_list(values, key)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, []}
    end
  end

  defp string_list(values, key) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, Enum.map(values, &String.trim/1)}
    else
      {:error, "invalid_field:#{key}"}
    end
  end

  defp validate_enum(attrs, key, allowed) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        if value in allowed do
          :ok
        else
          {:error, "invalid_field:#{key}"}
        end

      {:ok, _value} ->
        {:error, "invalid_field:#{key}"}

      :error ->
        :ok
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false
end
