defmodule HoltWorks.Tasks.ToolRegistry do
  @moduledoc """
  Structured availability snapshot for tools used by task-agent runs.

  This contract reports whether a tool is available from explicit runtime
  fields. It does not infer availability from task prose.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.{ActionContract, RuntimeContracts, TaskToolSession}

  @schema_version "holtworks_tool_availability/v1"

  def snapshot(attrs \\ %{})

  def snapshot(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    tool_names(attrs)
    |> Enum.map(&availability_record(&1, attrs))
  end

  def snapshot(_attrs), do: snapshot(%{})

  def availability_for(tool_availability, tool_name) when is_list(tool_availability) do
    Enum.find(tool_availability, fn
      %{"name" => ^tool_name} -> true
      _entry -> false
    end)
  end

  def availability_for(_tool_availability, _tool_name), do: nil

  def available?(tool_availability, tool_name) do
    case availability_for(tool_availability, tool_name) do
      %{"available" => available?} -> RuntimeContracts.truthy?(available?)
      _entry -> false
    end
  end

  defp tool_names(attrs) do
    explicit = RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "tool_names"))

    if explicit == [] do
      TaskToolSession.direct_tool_names() ++ TaskToolSession.meta_tool_names()
    else
      explicit
    end
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp availability_record(tool_name, attrs) do
    effect_scope = ActionContract.effect_scope(tool_name)
    unavailable_reason = unavailable_reason(tool_name, effect_scope, attrs)

    %{
      "schema_version" => @schema_version,
      "name" => tool_name,
      "category" => category(tool_name, effect_scope),
      "effect_scope" => effect_scope,
      "required_permission" => required_permission(effect_scope),
      "required_capability" => required_capability(tool_name, effect_scope),
      "requires_workspace" => requires_workspace?(effect_scope),
      "requires_network" => effect_scope == "external_side_effect",
      "requires_approval" =>
        ActionContract.requires_approval?(%{"effect_scope" => effect_scope, "risk_level" => nil}),
      "available" => is_nil(unavailable_reason),
      "unavailable_reason" => unavailable_reason,
      "retryable" => retryable?(unavailable_reason),
      "checked_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp unavailable_reason(_tool_name, effect_scope, attrs) do
    cond do
      effect_scope == "unknown" ->
        "tool_not_registered"

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
    RuntimeContracts.value(attrs, "workspace_status") == "missing" or
      RuntimeContracts.value(attrs, "blocker_code") == "workspace_required"
  end

  defp network_disabled?(attrs) do
    RuntimeContracts.value(attrs, "network_status") == "disabled" or
      RuntimeContracts.value(attrs, "network_enabled") == false
  end

  defp approval_blocked?(effect_scope, attrs) do
    effect_scope in ["workspace_durable", "external_side_effect"] and
      RuntimeContracts.value(attrs, "approval_status") == "denied"
  end

  defp retryable?("workspace_required"), do: true
  defp retryable?("approval_required"), do: false
  defp retryable?("network_disabled"), do: false
  defp retryable?("tool_not_registered"), do: false
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

  defp category(_tool_name, "read_only"), do: "read"
  defp category(_tool_name, "session_ephemeral"), do: "session"
  defp category(_tool_name, "task_durable"), do: "task"
  defp category(_tool_name, "agent_orchestration"), do: "agent_orchestration"
  defp category(_tool_name, "workspace_durable"), do: "workspace"
  defp category(_tool_name, "external_side_effect"), do: "external"
  defp category(_tool_name, "routed"), do: "router"
  defp category(_tool_name, _effect_scope), do: "unknown"

  defp required_permission("read_only"), do: "task_read"
  defp required_permission("session_ephemeral"), do: "session_write"
  defp required_permission("task_durable"), do: "task_write"
  defp required_permission("agent_orchestration"), do: "agent_orchestration"
  defp required_permission("workspace_durable"), do: "workspace_write"
  defp required_permission("external_side_effect"), do: "external_side_effect"
  defp required_permission("routed"), do: "task_tool_route"
  defp required_permission(_effect_scope), do: "unknown"

  defp required_capability("route_verification_review", _effect_scope), do: "verification_review"
  defp required_capability(_tool_name, "read_only"), do: "assigned_task_context"
  defp required_capability(_tool_name, "session_ephemeral"), do: "session_state_update"
  defp required_capability(_tool_name, "task_durable"), do: "task_state_update"
  defp required_capability(_tool_name, "agent_orchestration"), do: "agent_work_orchestration"
  defp required_capability(_tool_name, "workspace_durable"), do: "workspace_mutation"
  defp required_capability(_tool_name, "external_side_effect"), do: "external_operation"
  defp required_capability(_tool_name, "routed"), do: "task_tool_routing"
  defp required_capability(_tool_name, _effect_scope), do: "unknown"
end
