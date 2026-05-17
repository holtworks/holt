defmodule HoltWorks.Tasks.PolicyEngine do
  @moduledoc """
  Central policy decision for proposed task actions.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_policy_decision/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    context = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "context"))
    contract = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "action_contract"))
    plan_gate = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "plan_gate"))
    preflight = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "action_preflight"))
    rules = evaluated_rules(context, contract, plan_gate, preflight)
    decision = decisive_rule(rules)

    %{
      "schema_version" => @schema_version,
      "decision_id" =>
        RuntimeContracts.stable_id("policy", [
          contract["contract_id"],
          plan_gate["gate_id"],
          preflight["preflight_id"],
          decision
        ]),
      "action" => decision["outcome"],
      "reason" => decision["reason"],
      "rule_id" => decision["rule_id"],
      "effect_scope" => contract["effect_scope"],
      "risk_level" => contract["risk_level"],
      "target_domain" => contract["target_domain"],
      "preflight_id" => preflight["preflight_id"],
      "preflight_result" => preflight["result"],
      "requires_approval" => decision["outcome"] == "approval_required",
      "rules_evaluated" => rules,
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def evaluate(_attrs), do: evaluate(%{})

  defp evaluated_rules(context, contract, plan_gate, preflight) do
    [
      plan_gate_rule(plan_gate),
      known_effect_scope_rule(contract),
      verifier_read_only_rule(context, contract),
      preflight_rule(preflight),
      approval_rule(contract, preflight),
      default_allow_rule(contract)
    ]
  end

  defp decisive_rule(rules) do
    Enum.find(rules, &(&1["outcome"] in ["rejected", "approval_required", "approved"])) ||
      rule("policy_failed_closed", "rejected", "policy_engine_failed_closed")
  end

  defp plan_gate_rule(%{"action" => "approved"}),
    do: rule("plan_gate", "pass", "action_inside_active_plan")

  defp plan_gate_rule(%{"action" => "rejected"} = gate) do
    rule("plan_gate", "rejected", gate["reason"] || "plan_gate_rejected")
  end

  defp plan_gate_rule(%{"action" => "approval_required"} = gate) do
    rule("plan_gate", "approval_required", gate["reason"] || "plan_gate_requires_approval")
  end

  defp plan_gate_rule(_gate), do: rule("plan_gate", "rejected", "plan_gate_missing_or_unknown")

  defp known_effect_scope_rule(%{"effect_scope" => "unknown"}) do
    rule("known_effect_scope", "rejected", "unknown_effect_scope")
  end

  defp known_effect_scope_rule(_contract),
    do: rule("known_effect_scope", "pass", "known_effect_scope")

  defp verifier_read_only_rule(context, contract) do
    verifier? =
      context["work_role"] == "verifier" or context["agent_role"] == "verifier" or
        context["role"] == "verifier" or RuntimeContracts.truthy?(context["verifier_context"])

    mutating? = contract["effect_scope"] not in ["read_only", "routed"]

    if verifier? and mutating? and contract["tool_name"] != "route_verification_review" do
      rule("read_only_verifier_boundary", "rejected", "read_only_verifier_cannot_mutate")
    else
      rule("read_only_verifier_boundary", "pass", "not_a_verifier_mutation")
    end
  end

  defp preflight_rule(%{"result" => "passed"}),
    do: rule("action_preflight", "pass", "preflight_passed")

  defp preflight_rule(%{"result" => "approval_required"}) do
    rule("action_preflight", "approval_required", "action_preflight_requires_approval")
  end

  defp preflight_rule(%{"result" => "blocked"} = preflight) do
    reason =
      case preflight["blocked_checks"] do
        [check | _rest] -> "action_preflight_blocked:" <> to_string(check)
        _other -> "action_preflight_blocked"
      end

    rule("action_preflight", "rejected", reason)
  end

  defp preflight_rule(_preflight),
    do: rule("action_preflight", "rejected", "preflight_missing_or_unknown")

  defp approval_rule(contract, preflight) do
    cond do
      preflight["result"] == "approval_required" ->
        rule(
          "approval_policy",
          "approval_required",
          "human_approval_required_for:" <> contract["effect_scope"]
        )

      true ->
        rule("approval_policy", "pass", "approval_not_required")
    end
  end

  defp default_allow_rule(contract) do
    rule(
      "default_allow_after_contracts",
      "approved",
      "policy_contract_approved:" <> to_string(contract["effect_scope"])
    )
  end

  defp rule(rule_id, outcome, reason) do
    %{"rule_id" => rule_id, "outcome" => outcome, "reason" => reason}
  end
end
