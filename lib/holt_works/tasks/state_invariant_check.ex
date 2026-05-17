defmodule HoltWorks.Tasks.StateInvariantCheck do
  @moduledoc """
  Pre-execution invariant checks for typed state transitions.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.{ActionContract, RuntimeContracts}

  @schema_version "holtworks_state_invariant_check/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    context = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "context"))
    contract = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "action_contract"))
    snapshot = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "state_snapshot"))

    transition =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "state_transition_prediction"))

    rules = rules(context, contract, snapshot, transition)
    status = status(rules)

    %{
      "schema_version" => @schema_version,
      "check_id" =>
        RuntimeContracts.stable_id("state_invariant", [
          contract["contract_id"],
          snapshot["state_hash"],
          transition["transition_id"],
          rules
        ]),
      "status" => status,
      "action" => action(status),
      "reason" => reason(status, rules),
      "action_contract_id" => contract["contract_id"],
      "state_snapshot_id" => snapshot["snapshot_id"],
      "state_transition_id" => transition["transition_id"],
      "tool_name" => contract["tool_name"],
      "effect_scope" => contract["effect_scope"],
      "target_domain" => contract["target_domain"],
      "rules" => rules,
      "blocked_invariants" => rule_ids(rules, "blocked"),
      "approval_required_invariants" => rule_ids(rules, "approval_required"),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def evaluate(_attrs), do: evaluate(%{})

  defp rules(context, contract, snapshot, transition) do
    [
      known_effect_scope_rule(contract),
      stale_state_rule(snapshot),
      verifier_read_only_rule(context, contract),
      expected_changes_rule(contract, transition),
      recovery_rule(contract),
      observation_rule(contract, transition)
    ]
  end

  defp known_effect_scope_rule(contract) do
    if ActionContract.known_effect_scope?(contract["effect_scope"]) do
      rule("known_effect_scope", "passed", "known_effect_scope")
    else
      rule("known_effect_scope", "blocked", "unknown_effect_scope")
    end
  end

  defp stale_state_rule(snapshot) do
    staleness = RuntimeContracts.normalize_map(snapshot["staleness"])

    if RuntimeContracts.truthy?(staleness["stale"]) do
      rule("state_not_stale", "blocked", "state_snapshot_marked_stale")
    else
      rule("state_not_stale", "passed", "state_snapshot_not_stale")
    end
  end

  defp verifier_read_only_rule(context, contract) do
    verifier? =
      context["work_role"] == "verifier" or context["agent_role"] == "verifier" or
        context["role"] == "verifier" or RuntimeContracts.truthy?(context["verifier_context"])

    if verifier? and ActionContract.mutating_effect_scope?(contract["effect_scope"]) and
         contract["tool_name"] != "route_verification_review" do
      rule("read_only_verifier_boundary", "blocked", "read_only_verifier_cannot_mutate")
    else
      rule("read_only_verifier_boundary", "passed", "not_a_verifier_mutation")
    end
  end

  defp expected_changes_rule(contract, transition) do
    changes = transition["expected_changes"] || []

    cond do
      ActionContract.mutating_effect_scope?(contract["effect_scope"]) and changes == [] ->
        rule(
          "expected_state_changes_declared",
          "blocked",
          "mutating_action_missing_expected_state_changes"
        )

      true ->
        rule("expected_state_changes_declared", "passed", "expected_state_changes_declared")
    end
  end

  defp recovery_rule(contract) do
    recovery = RuntimeContracts.normalize_map(contract["recovery"])

    if ActionContract.mutating_effect_scope?(contract["effect_scope"]) and
         recovery["reversibility"] in [nil, "", "unknown"] do
      rule("recovery_declared", "blocked", "missing_recovery_contract")
    else
      rule("recovery_declared", "passed", "recovery_contract_present")
    end
  end

  defp observation_rule(contract, transition) do
    mutating? = ActionContract.mutating_effect_scope?(contract["effect_scope"])

    if mutating? and transition["requires_observation"] != true do
      rule("observation_required", "blocked", "mutating_action_missing_observation_requirement")
    else
      rule("observation_required", "passed", "observation_policy_declared")
    end
  end

  defp status(rules) do
    cond do
      Enum.any?(rules, &(&1["status"] == "blocked")) -> "blocked"
      Enum.any?(rules, &(&1["status"] == "approval_required")) -> "approval_required"
      true -> "passed"
    end
  end

  defp action("passed"), do: "approved"
  defp action("approval_required"), do: "approval_required"
  defp action(_status), do: "rejected"

  defp reason("passed", _rules), do: "state_invariants_passed"

  defp reason(_status, rules) do
    rules
    |> Enum.find(&(&1["status"] in ["blocked", "approval_required"]))
    |> case do
      nil -> "state_invariants_failed"
      rule -> rule["reason"]
    end
  end

  defp rule_ids(rules, status) do
    rules
    |> Enum.filter(&(&1["status"] == status))
    |> Enum.map(& &1["rule_id"])
  end

  defp rule(rule_id, status, reason) do
    %{"rule_id" => rule_id, "status" => status, "reason" => reason}
  end
end
