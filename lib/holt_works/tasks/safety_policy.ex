defmodule HoltWorks.Tasks.SafetyPolicy do
  @moduledoc """
  Declarative task-agent safety policy.

  Command validation belongs to tool ingress. This module only returns
  structured runtime policy metadata for other gates to consume.
  """

  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_safety_policy/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    complexity = RuntimeContracts.text(attrs, "task_complexity", "normal")

    %{
      "schema_version" => @schema_version,
      "permission_mode" => permission_mode(complexity),
      "tool_policy" => "registry_permissions_required",
      "command_policy" => "structured_tool_ingress_only",
      "destructive_action_policy" => "approval_required",
      "sandbox_policy" => sandbox_policy(complexity),
      "dead_letter_policy" => "record_async_failure_event",
      "retry_policy" => retry_policy(attrs),
      "approval_required_for" => approval_required_for(complexity)
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp permission_mode("trivial"), do: "minimal"
  defp permission_mode(_complexity), do: "least_privilege"

  defp sandbox_policy("implementation"), do: "required_for_code_or_services"
  defp sandbox_policy("broad_parallel"), do: "required_for_code_or_services"
  defp sandbox_policy(_complexity), do: "required_when_tools_request_runtime"

  defp retry_policy(attrs) do
    %{
      "max_attempts" =>
        positive_int(RuntimeContracts.value(attrs, "max_attempts")) ||
          1,
      "max_continuation_depth" =>
        nonnegative_int(RuntimeContracts.value(attrs, "max_continuation_depth")) ||
          1,
      "retryable_failure_classes" => ["agent_run_failed", "workspace_required"]
    }
  end

  defp approval_required_for("trivial"), do: ["destructive_action", "external_publish"]

  defp approval_required_for(_complexity),
    do: ["destructive_action", "external_publish", "permission_escalation"]

  defp positive_int(value) do
    case RuntimeContracts.integer(value) do
      int when int > 0 -> int
      _int -> nil
    end
  end

  defp nonnegative_int(value) do
    case RuntimeContracts.integer(value) do
      int when int >= 0 -> int
      _int -> nil
    end
  end
end
