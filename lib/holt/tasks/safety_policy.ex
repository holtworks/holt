defmodule Holt.Tasks.SafetyPolicy do
  @moduledoc """
  Declarative task-agent safety policy.

  Command validation belongs to action ingress. This module only returns
  structured runtime policy metadata for other gates to consume.
  """

  @schema_version "holt_safety_policy/v1"
  @task_complexities ~w(trivial normal implementation broad_parallel)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, complexity} <- task_complexity(attrs),
         {:ok, retry_policy} <- retry_policy(attrs) do
      %{
        "schema_version" => @schema_version,
        "permission_mode" => permission_mode(complexity),
        "action_policy" => "registry_permissions_required",
        "command_policy" => "structured_action_ingress_only",
        "destructive_action_policy" => "approval_required",
        "sandbox_policy" => sandbox_policy(complexity),
        "dead_letter_policy" => "record_async_failure_event",
        "retry_policy" => retry_policy,
        "approval_required_for" => approval_required_for(complexity)
      }
      |> reject_empty()
    else
      {:error, reason} -> rejected_policy(reason)
    end
  end

  def build(_attrs), do: rejected_policy("invalid_attrs")

  defp rejected_policy(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp permission_mode("trivial"), do: "minimal"
  defp permission_mode(_complexity), do: "least_privilege"

  defp sandbox_policy("implementation"), do: "required_for_code_or_services"
  defp sandbox_policy("broad_parallel"), do: "required_for_code_or_services"
  defp sandbox_policy(_complexity), do: "required_when_actions_request_runtime"

  defp approval_required_for("trivial"), do: ["destructive_action", "external_publish"]

  defp approval_required_for(_complexity),
    do: ["destructive_action", "external_publish", "permission_escalation"]

  defp retry_policy(attrs) do
    with {:ok, max_attempts} <- optional_positive_integer(attrs, "max_attempts", 1),
         {:ok, max_continuation_depth} <-
           optional_nonnegative_integer(attrs, "max_continuation_depth", 1) do
      {:ok,
       %{
         "max_attempts" => max_attempts,
         "max_continuation_depth" => max_continuation_depth,
         "retryable_failure_classes" => ["agent_run_failed", "workspace_required"]
       }}
    end
  end

  defp task_complexity(attrs) do
    case optional_text(attrs, "task_complexity", "normal") do
      {:ok, complexity} ->
        if complexity in @task_complexities do
          {:ok, complexity}
        else
          {:error, "invalid_field:task_complexity"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp optional_text(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "invalid_field:#{key}"}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, "invalid_field:#{key}"}

      :error ->
        {:ok, default}
    end
  end

  defp optional_positive_integer(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, default}
    end
  end

  defp optional_nonnegative_integer(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, default}
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
