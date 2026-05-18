defmodule Holt.Tasks.PolicyEngine do
  @moduledoc """
  Central policy decision for proposed task actions.
  """

  alias Holt.Clock
  alias Holt.Tasks.ActionContract

  @schema_version "holt_policy_decision/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> evaluate_canonical(input)
      {:error, reason} -> rejected_decision(attrs, reason)
    end
  end

  def evaluate(_attrs), do: rejected_decision(%{}, "invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, context} <- optional_context(attrs),
         {:ok, contract} <- action_contract(attrs),
         {:ok, plan_gate} <- plan_gate(attrs),
         {:ok, preflight} <- action_preflight(attrs) do
      {:ok,
       %{
         context: context,
         action_contract: contract,
         plan_gate: plan_gate,
         action_preflight: preflight
       }}
    end
  end

  defp evaluate_canonical(input) do
    context = input.context
    contract = input.action_contract
    plan_gate = input.plan_gate
    preflight = input.action_preflight
    rules = evaluated_rules(context, contract, plan_gate, preflight)
    decision = decisive_rule(rules)

    %{
      "schema_version" => @schema_version,
      "decision_id" =>
        stable_id("policy", [
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
    |> compact()
  end

  defp rejected_decision(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "decision_id" =>
        output_text(
          attrs,
          "decision_id",
          stable_id("policy", [reason, attrs])
        ),
      "action" => "rejected",
      "reason" => reason,
      "rule_id" => "invalid_policy_attrs",
      "requires_approval" => false,
      "created_at" => Clock.iso_now()
    }
  end

  defp optional_context(attrs) do
    case Map.fetch(attrs, "context") do
      {:ok, context} when is_map(context) ->
        with :ok <- optional_work_role(context),
             :ok <- optional_verifier_context(context) do
          {:ok, context}
        end

      {:ok, _context} ->
        {:error, "invalid_context"}

      :error ->
        {:ok, %{}}
    end
  end

  defp optional_work_role(context) do
    case Map.fetch(context, "work_role") do
      {:ok, value} when is_binary(value) -> :ok
      {:ok, _value} -> {:error, "invalid_context"}
      :error -> :ok
    end
  end

  defp optional_verifier_context(context) do
    case Map.fetch(context, "verifier_context") do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, "invalid_context"}
      :error -> :ok
    end
  end

  defp action_contract(attrs) do
    case Map.fetch(attrs, "action_contract") do
      {:ok, contract} when is_map(contract) ->
        with :ok <- validate_action_contract(contract) do
          {:ok, contract}
        end

      {:ok, _contract} ->
        {:error, "invalid_action_contract"}

      :error ->
        {:error, "missing_action_contract"}
    end
  end

  defp validate_action_contract(contract) do
    with {:ok, _contract_id} <- required_text(contract, "contract_id", "invalid_action_contract"),
         {:ok, _action} <- required_text(contract, "action", "invalid_action_contract"),
         {:ok, _effect_scope} <-
           required_text(contract, "effect_scope", "invalid_action_contract"),
         :ok <- optional_text_field(contract, "risk_level", "invalid_action_contract"),
         :ok <- optional_text_field(contract, "target_domain", "invalid_action_contract") do
      :ok
    end
  end

  defp plan_gate(attrs) do
    case Map.fetch(attrs, "plan_gate") do
      {:ok, gate} when is_map(gate) ->
        with :ok <- validate_plan_gate(gate) do
          {:ok, gate}
        end

      {:ok, _gate} ->
        {:error, "invalid_plan_gate"}

      :error ->
        {:error, "missing_plan_gate"}
    end
  end

  defp validate_plan_gate(gate) do
    with {:ok, _gate_id} <- required_text(gate, "gate_id", "invalid_plan_gate"),
         {:ok, action} <- required_text(gate, "action", "invalid_plan_gate"),
         :ok <- gate_action(action),
         :ok <- optional_text_field(gate, "reason", "invalid_plan_gate") do
      :ok
    end
  end

  defp gate_action("approved"), do: :ok
  defp gate_action("rejected"), do: :ok
  defp gate_action("approval_required"), do: :ok
  defp gate_action(_action), do: {:error, "invalid_plan_gate"}

  defp action_preflight(attrs) do
    case Map.fetch(attrs, "action_preflight") do
      {:ok, preflight} when is_map(preflight) ->
        with :ok <- validate_action_preflight(preflight) do
          {:ok, preflight}
        end

      {:ok, _preflight} ->
        {:error, "invalid_action_preflight"}

      :error ->
        {:error, "missing_action_preflight"}
    end
  end

  defp validate_action_preflight(preflight) do
    with {:ok, _preflight_id} <-
           required_text(preflight, "preflight_id", "invalid_action_preflight"),
         {:ok, result} <- required_text(preflight, "result", "invalid_action_preflight"),
         :ok <- preflight_result(result),
         :ok <- optional_string_list(preflight, "blocked_checks", "invalid_action_preflight"),
         :ok <-
           optional_string_list(
             preflight,
             "approval_required_checks",
             "invalid_action_preflight"
           ) do
      :ok
    end
  end

  defp preflight_result("passed"), do: :ok
  defp preflight_result("blocked"), do: :ok
  defp preflight_result("approval_required"), do: :ok
  defp preflight_result(_result), do: {:error, "invalid_action_preflight"}

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
    case Enum.find(rules, &(&1["outcome"] in ["rejected", "approval_required", "approved"])) do
      nil -> rule("policy_failed_closed", "rejected", "policy_engine_failed_closed")
      decision -> decision
    end
  end

  defp plan_gate_rule(%{"action" => "approved"}),
    do: rule("plan_gate", "pass", "action_inside_active_plan")

  defp plan_gate_rule(%{"action" => "rejected"} = gate) do
    rule("plan_gate", "rejected", text_default(text_field(gate, "reason"), "plan_gate_rejected"))
  end

  defp plan_gate_rule(%{"action" => "approval_required"} = gate) do
    rule(
      "plan_gate",
      "approval_required",
      text_default(text_field(gate, "reason"), "plan_gate_requires_approval")
    )
  end

  defp known_effect_scope_rule(contract) do
    case ActionContract.known_effect_scope?(contract["effect_scope"]) do
      true -> rule("known_effect_scope", "pass", "known_effect_scope")
      false -> rule("known_effect_scope", "rejected", "unknown_effect_scope")
    end
  end

  defp verifier_read_only_rule(context, contract) do
    mutating? = ActionContract.mutating_effect_scope?(contract["effect_scope"])

    case {verifier_context?(context), mutating?, contract["action"]} do
      {true, true, action} when action != "route_verification_review" ->
        rule("read_only_verifier_boundary", "rejected", "read_only_verifier_cannot_mutate")

      _allowed ->
        rule("read_only_verifier_boundary", "pass", "not_a_verifier_mutation")
    end
  end

  defp verifier_context?(%{"work_role" => "verifier"}), do: true
  defp verifier_context?(%{"verifier_context" => true}), do: true
  defp verifier_context?(_context), do: false

  defp preflight_rule(%{"result" => "passed"}),
    do: rule("action_preflight", "pass", "preflight_passed")

  defp preflight_rule(%{"result" => "approval_required"}) do
    rule("action_preflight", "approval_required", "action_preflight_requires_approval")
  end

  defp preflight_rule(%{"result" => "blocked"} = preflight) do
    reason =
      case preflight["blocked_checks"] do
        [check | _rest] when is_binary(check) -> "action_preflight_blocked:" <> check
        _other -> "action_preflight_blocked"
      end

    rule("action_preflight", "rejected", reason)
  end

  defp approval_rule(contract, preflight) do
    case preflight["result"] do
      "approval_required" ->
        rule(
          "approval_policy",
          "approval_required",
          "human_approval_required_for:" <> contract["effect_scope"]
        )

      _result ->
        rule("approval_policy", "pass", "approval_not_required")
    end
  end

  defp default_allow_rule(contract) do
    rule(
      "default_allow_after_contracts",
      "approved",
      "policy_contract_approved:" <> contract["effect_scope"]
    )
  end

  defp rule(rule_id, outcome, reason) do
    %{"rule_id" => rule_id, "outcome" => outcome, "reason" => reason}
  end

  defp canonical_attrs(attrs) do
    case canonical_value?(attrs) do
      true -> :ok
      false -> {:error, "invalid_attrs"}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      _entry -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp required_text(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:error, reason}
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          _text -> :ok
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        validate_string_list(values, reason)

      {:ok, _values} ->
        {:error, reason}

      :error ->
        :ok
    end
  end

  defp validate_string_list(values, reason) do
    case Enum.all?(values, &is_binary/1) do
      true -> :ok
      false -> {:error, reason}
    end
  end

  defp text_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _missing_or_invalid ->
        nil
    end
  end

  defp text_field(_map, _key), do: nil

  defp output_text(map, key, default) when is_map(map) do
    case text_field(map, key) do
      nil -> default
      text -> text
    end
  end

  defp output_text(_map, _key, default), do: default

  defp text_default(nil, default), do: default
  defp text_default(value, _default), do: value

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
