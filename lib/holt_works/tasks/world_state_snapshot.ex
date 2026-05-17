defmodule HoltWorks.Tasks.WorldStateSnapshot do
  @moduledoc """
  Compact structured state snapshot captured before a task action.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_world_state_snapshot/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    context = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "context"))
    contract = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "action_contract"))
    plan = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "plan_contract"))
    task = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "task"))
    target_refs = RuntimeContracts.normalize_map(contract["target_refs"])

    snapshot =
      %{
        "schema_version" => @schema_version,
        "scope" => "pre_action",
        "action_contract_id" => contract["contract_id"],
        "tool_name" => contract["tool_name"],
        "effect_scope" => contract["effect_scope"],
        "target_domain" => contract["target_domain"],
        "task_state" => task_state(context, task, target_refs),
        "agent_state" => agent_state(context),
        "plan_state" => plan_state(plan),
        "resource_refs" => target_refs,
        "permission_state" => permission_state(context),
        "staleness" => staleness(context),
        "captured_at" => Clock.iso_now()
      }
      |> RuntimeContracts.reject_empty()

    snapshot
    |> Map.put("snapshot_id", RuntimeContracts.stable_id("world_state", [snapshot]))
    |> Map.put(
      "state_hash",
      RuntimeContracts.stable_id("state_hash", [Map.drop(snapshot, ["captured_at"])])
    )
  end

  def build(_attrs), do: build(%{})

  defp task_state(context, task, target_refs) do
    %{
      "task_id" => task["id"] || context["task_id"] || target_refs["task_id"],
      "task_ref" => task["ref"] || context["task_ref"] || target_refs["task_ref"],
      "task_title" => task["title"],
      "task_status" => task["status"],
      "parent_task_id" => task["parent_id"] || context["parent_task_id"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp agent_state(context) do
    %{
      "agent_id" => context["agent_id"],
      "agent_ref" => context["agent_ref"],
      "run_id" => context["run_id"] || context["agent_run_id"],
      "work_role" => context["work_role"] || context["agent_role"] || context["role"],
      "autonomous" => RuntimeContracts.truthy?(context["autonomous"])
    }
    |> RuntimeContracts.reject_empty()
  end

  defp plan_state(plan) do
    %{
      "plan_id" => plan["plan_id"],
      "allowed_tools" => plan["allowed_tools"] || [],
      "allowed_effect_scopes" => plan["allowed_effect_scopes"] || [],
      "status" => plan["status"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp permission_state(context) do
    %{
      "approval_granted" => approval_granted?(context),
      "approval_source" => approval_source(context),
      "verifier_context" => verifier_context?(context)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp staleness(context) do
    stale? =
      RuntimeContracts.truthy?(context["stale_state_detected"]) or
        RuntimeContracts.truthy?(context["resource_stale"])

    %{
      "stale" => stale?,
      "markers" =>
        [
          if(RuntimeContracts.truthy?(context["stale_state_detected"]),
            do: "stale_state_detected"
          ),
          if(RuntimeContracts.truthy?(context["resource_stale"]), do: "resource_stale")
        ]
        |> Enum.reject(&is_nil/1)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp approval_granted?(context) do
    RuntimeContracts.truthy?(context["approval_already_granted"]) or
      RuntimeContracts.truthy?(context["policy_approval_granted"]) or
      context["approval_status"] == "approved"
  end

  defp approval_source(context) do
    cond do
      RuntimeContracts.truthy?(context["approval_already_granted"]) -> "action_context"
      RuntimeContracts.truthy?(context["policy_approval_granted"]) -> "policy_context"
      context["approval_status"] == "approved" -> "approval_status"
      true -> nil
    end
  end

  defp verifier_context?(context) do
    context["work_role"] == "verifier" or context["agent_role"] == "verifier" or
      context["role"] == "verifier" or RuntimeContracts.truthy?(context["verifier_context"])
  end
end
