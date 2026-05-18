defmodule Holt.Tasks.RecoveryContract do
  @moduledoc """
  Rollback and forward-recovery contract for one proposed action.

  Mutating actions declare whether they can be undone, how recovery should be
  attempted, and which observation proves the recovery worked.
  """

  alias Holt.Clock

  @schema_version "holt_recovery_contract/v1"
  @effect_scopes ~w(
    read_only
    session_ephemeral
    routed
    task_durable
    agent_orchestration
    workspace_durable
    external_side_effect
    unknown
  )
  @risk_levels ~w(low medium high critical)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, action} <- optional_text(attrs, "action", "unknown"),
         {:ok, scope} <- optional_enum(attrs, "effect_scope", @effect_scopes, "unknown"),
         {:ok, risk} <- optional_enum(attrs, "risk_level", @risk_levels, "high"),
         {:ok, target_refs} <- map_field(attrs, "target_refs") do
      %{
        "schema_version" => @schema_version,
        "recovery_id" => stable_id("recovery", [action, scope, risk, target_refs]),
        "action" => action,
        "effect_scope" => scope,
        "risk_level" => risk,
        "reversibility" => reversibility(scope),
        "rollback_plan" => rollback_plan(scope, target_refs),
        "forward_recovery_plan" => forward_recovery_plan(scope, risk),
        "requires_recovery_observation" => scope not in ["read_only", "session_ephemeral"],
        "requires_rollback_verification" =>
          scope in ["task_durable", "workspace_durable", "agent_orchestration"],
        "irreversible_risk" => scope in ["external_side_effect", "unknown"],
        "created_at" => Clock.iso_now()
      }
      |> reject_empty()
    else
      {:error, reason} -> rejected_contract(reason)
    end
  end

  def build(_attrs), do: rejected_contract("invalid_attrs")

  defp rejected_contract(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp reversibility("read_only"), do: "none_required"
  defp reversibility("session_ephemeral"), do: "overwrite_session_state"
  defp reversibility("routed"), do: "delegated_to_nested_contract"
  defp reversibility("task_durable"), do: "reversible_with_compensating_update"
  defp reversibility("agent_orchestration"), do: "partially_reversible"
  defp reversibility("workspace_durable"), do: "partially_reversible"
  defp reversibility("external_side_effect"), do: "possibly_irreversible"
  defp reversibility(_scope), do: "unknown"

  defp rollback_plan("read_only", _target_refs) do
    %{"available" => true, "strategy" => "none_required", "steps" => []}
  end

  defp rollback_plan("session_ephemeral", _target_refs) do
    %{
      "available" => true,
      "strategy" => "overwrite_session_state",
      "steps" => ["restore or replace local session state"]
    }
  end

  defp rollback_plan("routed", target_refs) do
    %{
      "available" => true,
      "strategy" => "nested_route_contract",
      "target_refs" => target_refs,
      "steps" => ["use the nested route action contract and observation record"]
    }
  end

  defp rollback_plan("task_durable", target_refs) do
    %{
      "available" => true,
      "strategy" => "compensating_task_update",
      "target_refs" => target_refs,
      "steps" => [
        "reload the affected task or artifact",
        "write a compensating update or status correction",
        "record the correction in task activity"
      ]
    }
  end

  defp rollback_plan("agent_orchestration", target_refs) do
    %{
      "available" => true,
      "strategy" => "cancel_or_mark_blocked",
      "target_refs" => target_refs,
      "steps" => ["cancel queued child work or record a blocking handoff"]
    }
  end

  defp rollback_plan("workspace_durable", target_refs) do
    %{
      "available" => true,
      "strategy" => "workspace_revert_or_compensate",
      "target_refs" => target_refs,
      "steps" => [
        "inspect changed workspace state",
        "revert files when possible",
        "record remaining risk before continuing"
      ]
    }
  end

  defp rollback_plan("external_side_effect", target_refs) do
    %{
      "available" => false,
      "strategy" => "external_revert_may_be_impossible",
      "target_refs" => target_refs,
      "steps" => ["verify external state", "use provider-specific revert only with approval"]
    }
  end

  defp rollback_plan(_scope, target_refs) do
    %{
      "available" => false,
      "strategy" => "unknown",
      "target_refs" => target_refs,
      "steps" => ["stop and model the effect scope before retry"]
    }
  end

  defp forward_recovery_plan("read_only", _risk) do
    %{"on_failure" => "retry_with_more_specific_query", "max_retries" => 1}
  end

  defp forward_recovery_plan("session_ephemeral", _risk) do
    %{"on_failure" => "reset_session_state_and_retry", "max_retries" => 1}
  end

  defp forward_recovery_plan(_scope, "critical") do
    %{"on_failure" => "block_and_request_human_review", "max_retries" => 0}
  end

  defp forward_recovery_plan(_scope, "high") do
    %{"on_failure" => "route_verification_or_human_review", "max_retries" => 1}
  end

  defp forward_recovery_plan(_scope, _risk) do
    %{"on_failure" => "enter_repair_phase_with_new_prediction", "max_retries" => 1}
  end

  defp optional_text(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> text_value(key, value)
      :error -> {:ok, default}
    end
  end

  defp optional_enum(attrs, key, allowed, default) do
    case optional_text(attrs, key, default) do
      {:ok, value} ->
        if Enum.member?(allowed, value) do
          {:ok, value}
        else
          {:error, "invalid_field:#{key}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp text_value(key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "invalid_field:#{key}"}
      text -> {:ok, text}
    end
  end

  defp text_value(key, _value), do: {:error, "invalid_field:#{key}"}

  defp map_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> canonical_nested_map(key, value)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, %{}}
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp canonical_nested_map(key, map) do
    if canonical_value?(map) do
      {:ok, map}
    else
      {:error, "invalid_field:#{key}"}
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

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
