defmodule HoltWorks.Tasks.RecoveryContract do
  @moduledoc """
  Rollback and forward-recovery contract for one proposed action.

  Mutating actions declare whether they can be undone, how recovery should be
  attempted, and which observation proves the recovery worked.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_recovery_contract/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    scope = RuntimeContracts.text(attrs, "effect_scope", "unknown")
    risk = RuntimeContracts.text(attrs, "risk_level", "high")
    tool_name = RuntimeContracts.text(attrs, "tool_name", "unknown")
    target_refs = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "target_refs"))

    %{
      "schema_version" => @schema_version,
      "recovery_id" =>
        RuntimeContracts.stable_id("recovery", [tool_name, scope, risk, target_refs]),
      "tool_name" => tool_name,
      "effect_scope" => scope,
      "risk_level" => risk,
      "reversibility" => reversibility(scope),
      "rollback_plan" => rollback_plan(scope, target_refs),
      "forward_recovery_plan" => forward_recovery_plan(scope, risk),
      "requires_recovery_observation" => scope != "read_only",
      "requires_rollback_verification" =>
        scope in ["task_durable", "workspace_durable", "agent_orchestration"],
      "irreversible_risk" => scope in ["external_side_effect", "unknown"],
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp reversibility("read_only"), do: "none_required"
  defp reversibility("routed"), do: "delegated_to_nested_contract"
  defp reversibility("task_durable"), do: "reversible_with_compensating_update"
  defp reversibility("agent_orchestration"), do: "partially_reversible"
  defp reversibility("workspace_durable"), do: "partially_reversible"
  defp reversibility("external_side_effect"), do: "possibly_irreversible"
  defp reversibility(_scope), do: "unknown"

  defp rollback_plan("read_only", _target_refs) do
    %{"available" => true, "strategy" => "none_required", "steps" => []}
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

  defp forward_recovery_plan(_scope, "critical") do
    %{"on_failure" => "block_and_request_human_review", "max_retries" => 0}
  end

  defp forward_recovery_plan(_scope, "high") do
    %{"on_failure" => "route_verification_or_human_review", "max_retries" => 1}
  end

  defp forward_recovery_plan(_scope, _risk) do
    %{"on_failure" => "enter_repair_phase_with_new_prediction", "max_retries" => 1}
  end
end
