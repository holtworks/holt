defmodule HoltWorks.Tasks.StateTransitionPrediction do
  @moduledoc """
  Predicts the structured state changes expected from an action.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_state_transition_prediction/v1"
  @mutating_scopes ~w(task_durable agent_orchestration workspace_durable external_side_effect)

  def predict(attrs \\ %{})

  def predict(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    contract = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "action_contract"))
    prediction = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "prediction"))
    snapshot = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "state_snapshot"))
    scope = contract["effect_scope"] || prediction["effect_scope"] || "unknown"
    domain = contract["target_domain"] || prediction["target_domain"] || "unknown"
    target_refs = RuntimeContracts.normalize_map(contract["target_refs"])
    expected_changes = expected_changes(scope, domain, target_refs)

    %{
      "schema_version" => @schema_version,
      "transition_id" =>
        RuntimeContracts.stable_id("state_transition", [
          contract["contract_id"],
          snapshot["state_hash"],
          expected_changes
        ]),
      "action_contract_id" => contract["contract_id"],
      "prediction_id" => prediction["prediction_id"],
      "state_snapshot_id" => snapshot["snapshot_id"],
      "tool_name" => contract["tool_name"],
      "effect_scope" => scope,
      "target_domain" => domain,
      "expected_changes" => expected_changes,
      "possible_side_effects" => possible_side_effects(scope, domain),
      "failure_modes" => prediction["possible_failures"] || [],
      "requires_observation" => scope in @mutating_scopes,
      "confidence" => prediction["confidence"],
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def predict(_attrs), do: predict(%{})

  defp expected_changes("read_only", domain, target_refs) do
    [
      change("read_context", "context", target_ref(domain, target_refs), "read", "none", false)
      |> Map.put("durable", false)
    ]
  end

  defp expected_changes("routed", domain, target_refs) do
    [
      change(
        "route_nested_action",
        domain,
        target_ref(domain, target_refs),
        "route",
        "nested",
        false
      )
      |> Map.put("durable", false)
    ]
  end

  defp expected_changes("task_durable", domain, target_refs) do
    [
      change(
        "update_task_state",
        domain,
        target_ref(domain, target_refs),
        "create_or_update",
        "durable",
        true
      )
    ]
  end

  defp expected_changes("agent_orchestration", domain, target_refs) do
    [
      change(
        "create_agent_work",
        domain,
        target_ref(domain, target_refs),
        "queue_or_continue",
        "durable_orchestration",
        true
      )
    ]
  end

  defp expected_changes("workspace_durable", domain, target_refs) do
    [
      change(
        "update_workspace_state",
        domain,
        target_ref(domain, target_refs),
        "write_or_execute",
        "workspace_durable",
        true
      )
    ]
  end

  defp expected_changes("external_side_effect", domain, target_refs) do
    [
      change(
        "update_external_state",
        domain,
        target_ref(domain, target_refs),
        "external_mutation",
        "external_durable",
        true
      )
    ]
  end

  defp expected_changes(_scope, domain, target_refs) do
    [
      change(
        "unknown_state_change",
        domain,
        target_ref(domain, target_refs),
        "unknown",
        "unknown",
        true
      )
    ]
  end

  defp change(code, namespace, target_ref, operation, durability, verification_required?) do
    state_key =
      [namespace, target_ref, code]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(":")

    %{
      "change_id" => RuntimeContracts.stable_id("state_change", [code, namespace, target_ref]),
      "code" => code,
      "state_namespace" => namespace,
      "state_key" => state_key,
      "target_ref" => target_ref,
      "operation" => operation,
      "durability" => durability,
      "verification_required" => verification_required?
    }
    |> RuntimeContracts.reject_empty()
  end

  defp target_ref(_domain, %{"task_ref" => ref}) when ref not in [nil, ""], do: ref
  defp target_ref(_domain, %{"task_id" => id}) when id not in [nil, ""], do: id
  defp target_ref(_domain, %{"path" => path}) when path not in [nil, ""], do: path
  defp target_ref(domain, _target_refs), do: domain

  defp possible_side_effects("read_only", _domain), do: []
  defp possible_side_effects("routed", _domain), do: ["nested_contract_required"]
  defp possible_side_effects("task_durable", domain), do: ["audit_log", "#{domain}_updated"]
  defp possible_side_effects("agent_orchestration", _domain), do: ["agent_run_created"]

  defp possible_side_effects("workspace_durable", _domain),
    do: ["files_or_process_state_may_change"]

  defp possible_side_effects("external_side_effect", domain),
    do: ["#{domain}_remote_state_changed"]

  defp possible_side_effects(_scope, _domain), do: ["unknown_side_effect"]
end
