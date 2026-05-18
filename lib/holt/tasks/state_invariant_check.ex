defmodule Holt.Tasks.StateInvariantCheck do
  @moduledoc """
  Pre-execution invariant checks for typed state transitions.
  """

  alias Holt.Clock
  alias Holt.Tasks.ActionContract

  @schema_version "holt_state_invariant_check/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> evaluate_canonical(input)
      {:error, reason} -> rejected_check(attrs, reason)
    end
  end

  def evaluate(_attrs), do: rejected_check(%{}, "invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, context} <- optional_context(attrs),
         {:ok, contract} <- action_contract(attrs),
         {:ok, snapshot} <- state_snapshot(attrs),
         {:ok, transition} <- state_transition(attrs) do
      {:ok,
       %{
         context: context,
         action_contract: contract,
         state_snapshot: snapshot,
         state_transition_prediction: transition
       }}
    end
  end

  defp evaluate_canonical(input) do
    context = input.context
    contract = input.action_contract
    snapshot = input.state_snapshot
    transition = input.state_transition_prediction

    rules = rules(context, contract, snapshot, transition)
    status = status(rules)

    %{
      "schema_version" => @schema_version,
      "check_id" =>
        stable_id("state_invariant", [
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
      "target_action" => contract["action"],
      "effect_scope" => contract["effect_scope"],
      "target_domain" => contract["target_domain"],
      "rules" => rules,
      "blocked_invariants" => rule_ids(rules, "blocked"),
      "approval_required_invariants" => rule_ids(rules, "approval_required"),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_check(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "check_id" =>
        output_text(
          attrs,
          "check_id",
          stable_id("state_invariant", [reason, attrs])
        ),
      "status" => "rejected",
      "action" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp optional_context(attrs) do
    case Map.fetch(attrs, "context") do
      {:ok, context} when is_map(context) ->
        with :ok <- optional_text_field(context, "work_role", "invalid_context"),
             :ok <- optional_boolean_field(context, "verifier_context", "invalid_context") do
          {:ok, context}
        end

      {:ok, _context} ->
        {:error, "invalid_context"}

      :error ->
        {:ok, %{}}
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
         {:ok, _target_domain} <-
           required_text(contract, "target_domain", "invalid_action_contract"),
         :ok <- optional_recovery(contract) do
      :ok
    end
  end

  defp optional_recovery(contract) do
    case Map.fetch(contract, "recovery") do
      {:ok, recovery} when is_map(recovery) ->
        optional_text_field(recovery, "reversibility", "invalid_action_contract")

      {:ok, _recovery} ->
        {:error, "invalid_action_contract"}

      :error ->
        :ok
    end
  end

  defp state_snapshot(attrs) do
    case Map.fetch(attrs, "state_snapshot") do
      {:ok, snapshot} when is_map(snapshot) ->
        with :ok <- validate_state_snapshot(snapshot) do
          {:ok, snapshot}
        end

      {:ok, _snapshot} ->
        {:error, "invalid_state_snapshot"}

      :error ->
        {:error, "missing_state_snapshot"}
    end
  end

  defp validate_state_snapshot(snapshot) do
    with {:ok, _snapshot_id} <- required_text(snapshot, "snapshot_id", "invalid_state_snapshot"),
         {:ok, _state_hash} <- required_text(snapshot, "state_hash", "invalid_state_snapshot"),
         :ok <- optional_staleness(snapshot) do
      :ok
    end
  end

  defp optional_staleness(snapshot) do
    case Map.fetch(snapshot, "staleness") do
      {:ok, staleness} when is_map(staleness) ->
        optional_boolean_field(staleness, "stale", "invalid_state_snapshot")

      {:ok, _staleness} ->
        {:error, "invalid_state_snapshot"}

      :error ->
        :ok
    end
  end

  defp state_transition(attrs) do
    case Map.fetch(attrs, "state_transition_prediction") do
      {:ok, transition} when is_map(transition) ->
        with :ok <- validate_state_transition(transition) do
          {:ok, transition}
        end

      {:ok, _transition} ->
        {:error, "invalid_state_transition_prediction"}

      :error ->
        {:error, "missing_state_transition_prediction"}
    end
  end

  defp validate_state_transition(transition) do
    with {:ok, _transition_id} <-
           required_text(transition, "transition_id", "invalid_state_transition_prediction"),
         :ok <-
           optional_boolean_field(
             transition,
             "requires_observation",
             "invalid_state_transition_prediction"
           ),
         :ok <-
           optional_list(transition, "expected_changes", "invalid_state_transition_prediction") do
      :ok
    end
  end

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
    case ActionContract.known_effect_scope?(contract["effect_scope"]) do
      true -> rule("known_effect_scope", "passed", "known_effect_scope")
      false -> rule("known_effect_scope", "blocked", "unknown_effect_scope")
    end
  end

  defp stale_state_rule(snapshot) do
    staleness = staleness(snapshot)

    case staleness["stale"] do
      true -> rule("state_not_stale", "blocked", "state_snapshot_marked_stale")
      _not_stale -> rule("state_not_stale", "passed", "state_snapshot_not_stale")
    end
  end

  defp verifier_read_only_rule(context, contract) do
    mutating? = ActionContract.mutating_effect_scope?(contract["effect_scope"])

    case {verifier_context?(context), mutating?, contract["action"]} do
      {true, true, action} when action != "route_verification_review" ->
        rule("read_only_verifier_boundary", "blocked", "read_only_verifier_cannot_mutate")

      _allowed ->
        rule("read_only_verifier_boundary", "passed", "not_a_verifier_mutation")
    end
  end

  defp verifier_context?(%{"work_role" => "verifier"}), do: true
  defp verifier_context?(%{"verifier_context" => true}), do: true
  defp verifier_context?(_context), do: false

  defp expected_changes_rule(contract, transition) do
    changes = list_value(transition, "expected_changes")

    case {ActionContract.mutating_effect_scope?(contract["effect_scope"]), changes} do
      {true, []} ->
        rule(
          "expected_state_changes_declared",
          "blocked",
          "mutating_action_missing_expected_state_changes"
        )

      _declared ->
        rule("expected_state_changes_declared", "passed", "expected_state_changes_declared")
    end
  end

  defp recovery_rule(contract) do
    recovery = recovery(contract)

    case {ActionContract.mutating_effect_scope?(contract["effect_scope"]),
          recovery["reversibility"]} do
      {true, value} when value in [nil, "", "unknown"] ->
        rule("recovery_declared", "blocked", "missing_recovery_contract")

      _declared ->
        rule("recovery_declared", "passed", "recovery_contract_present")
    end
  end

  defp observation_rule(contract, transition) do
    mutating? = ActionContract.mutating_effect_scope?(contract["effect_scope"])

    case {mutating?, transition["requires_observation"]} do
      {true, value} when value != true ->
        rule("observation_required", "blocked", "mutating_action_missing_observation_requirement")

      _declared ->
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

  defp recovery(%{"recovery" => recovery}) when is_map(recovery), do: recovery
  defp recovery(_contract), do: %{}

  defp staleness(%{"staleness" => staleness}) when is_map(staleness), do: staleness
  defp staleness(_snapshot), do: %{}

  defp list_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> values
      _missing -> []
    end
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

  defp unsupported_arguments(attrs) do
    case Map.has_key?(attrs, "contract") do
      true -> {:error, "unsupported_argument:contract"}
      false -> :ok
    end
  end

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

  defp optional_boolean_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp optional_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> validate_map_list(values, reason)
      {:ok, _values} -> {:error, reason}
      :error -> :ok
    end
  end

  defp validate_map_list(values, reason) do
    case Enum.all?(values, &is_map/1) do
      true -> :ok
      false -> {:error, reason}
    end
  end

  defp output_text(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          text -> text
        end

      _missing ->
        default
    end
  end

  defp output_text(_map, _key, default), do: default

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
