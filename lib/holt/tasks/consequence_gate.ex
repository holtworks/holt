defmodule Holt.Tasks.ConsequenceGate do
  @moduledoc """
  Pre-execution consequence gate for task-scoped action actions.
  """

  alias Holt.Clock

  alias Holt.Tasks.{
    ConsequencePredictor,
    PolicyEngine,
    StateInvariantCheck,
    StateTransitionPrediction,
    WorldStateSnapshot
  }

  @schema_version "holt_consequence_gate/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> evaluate_canonical(input)
      {:error, reason} -> rejected_gate(attrs, reason)
    end
  end

  def evaluate(_attrs), do: rejected_gate(%{}, "invalid_attrs")

  def route(attrs \\ %{}) do
    gate = evaluate(attrs)

    case gate["action"] do
      "approved" -> {:approved, gate}
      "approval_required" -> {:approval_required, gate}
      _action -> {:rejected, gate}
    end
  end

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_aliases(attrs),
         {:ok, context} <- optional_map_value(attrs, "context", "invalid_context"),
         {:ok, task} <- optional_map_value(attrs, "task", "invalid_task"),
         {:ok, action_route} <- action_route(attrs),
         {:ok, action_contract} <- action_contract(attrs),
         {:ok, plan_contract} <- plan_contract(attrs),
         {:ok, plan_gate} <- plan_gate(attrs),
         {:ok, action_preflight} <- action_preflight(attrs),
         {:ok, policy_decision} <- optional_policy_decision(attrs),
         {:ok, prediction} <- optional_consequence_prediction(attrs),
         {:ok, state_snapshot} <- optional_state_snapshot(attrs),
         {:ok, state_transition} <- optional_state_transition(attrs),
         {:ok, state_invariant} <- optional_state_invariant(attrs) do
      {:ok,
       %{
         context: context,
         task: task,
         action_route: action_route,
         action_contract: action_contract,
         plan_contract: plan_contract,
         plan_gate: plan_gate,
         action_preflight: action_preflight,
         policy_decision: policy_decision,
         prediction: prediction,
         state_snapshot: state_snapshot,
         state_transition_prediction: state_transition,
         state_invariant_check: state_invariant
       }}
    end
  end

  defp evaluate_canonical(input) do
    context = input.context
    contract = input.action_contract
    plan = input.plan_contract
    plan_gate = input.plan_gate
    preflight = input.action_preflight

    policy =
      policy_decision(input.policy_decision, %{
        "context" => context,
        "plan_contract" => plan,
        "plan_gate" => plan_gate,
        "action_preflight" => preflight,
        "action_contract" => contract
      })

    prediction = consequence_prediction(input.prediction, contract, plan, plan_gate, preflight)
    snapshot = state_snapshot(input.state_snapshot, context, contract, plan, input.task)

    transition =
      state_transition_prediction(
        input.state_transition_prediction,
        contract,
        prediction,
        snapshot
      )

    invariant =
      state_invariant_check(input.state_invariant_check, context, contract, snapshot, transition)

    action = final_action(policy["action"], invariant["action"])

    %{
      "schema_version" => @schema_version,
      "gate_id" =>
        stable_id("consequence_gate", [
          plan_gate["gate_id"],
          preflight["preflight_id"],
          contract["contract_id"],
          prediction["prediction_id"],
          invariant["check_id"]
        ]),
      "action" => action,
      "reason" => decision_reason(action, policy, invariant, contract),
      "enforced" => true,
      "policy" => "active_plan_policy_engine_consequence_contract_v1",
      "policy_decision" => policy,
      "plan_contract" => plan,
      "plan_gate" => plan_gate,
      "action_preflight" => preflight,
      "action_contract" => contract,
      "action_route" => input.action_route,
      "prediction" => prediction,
      "state_snapshot" => snapshot,
      "state_transition_prediction" => transition,
      "state_invariant_check" => invariant,
      "requires_observation" => action == "approved",
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp action_route(attrs) do
    case Map.fetch(attrs, "action_route") do
      {:ok, route} when is_map(route) ->
        validate_action_route(route)

      {:ok, _route} ->
        {:error, "invalid_action_route"}

      :error ->
        {:error, "missing_action_route"}
    end
  end

  defp validate_action_route(route) do
    with {:ok, status} <- required_text(route, "status", "invalid_action_route"),
         :ok <- route_status(status),
         {:ok, reason} <- optional_text(route, "reason", "invalid_action_route"),
         :ok <- optional_embedded_action_contract(route) do
      route =
        route
        |> Map.put("status", status)
        |> put_optional("reason", reason)

      {:ok, route}
    end
  end

  defp route_status("accepted"), do: :ok
  defp route_status("rejected"), do: :ok
  defp route_status(_status), do: {:error, "invalid_action_route"}

  defp optional_embedded_action_contract(route) do
    case Map.fetch(route, "action_contract") do
      :error ->
        :ok

      {:ok, contract} when is_map(contract) ->
        case validate_action_contract(contract) do
          :ok -> :ok
          {:error, _reason} -> {:error, "invalid_action_route"}
        end

      {:ok, _contract} ->
        {:error, "invalid_action_route"}
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
         :ok <- optional_map(contract, "target_refs", "invalid_action_contract"),
         :ok <- optional_map(contract, "recovery", "invalid_action_contract"),
         :ok <- optional_text_field(contract, "risk_level", "invalid_action_contract"),
         :ok <- optional_text_field(contract, "target_domain", "invalid_action_contract"),
         :ok <- optional_text_field(contract, "idempotency_key", "invalid_action_contract") do
      :ok
    end
  end

  defp plan_contract(attrs) do
    case Map.fetch(attrs, "plan_contract") do
      {:ok, plan} when is_map(plan) ->
        with :ok <- validate_plan_contract(plan) do
          {:ok, plan}
        end

      {:ok, _plan} ->
        {:error, "invalid_plan_contract"}

      :error ->
        {:error, "missing_plan_contract"}
    end
  end

  defp validate_plan_contract(plan) do
    with {:ok, _plan_id} <- required_text(plan, "plan_id", "invalid_plan_contract"),
         {:ok, status} <- required_text(plan, "status", "invalid_plan_contract"),
         :ok <- plan_status(status),
         :ok <- required_string_list(plan, "allowed_actions", "invalid_plan_contract"),
         :ok <- required_string_list(plan, "allowed_effect_scopes", "invalid_plan_contract"),
         :ok <- plan_steps(plan) do
      :ok
    end
  end

  defp plan_status("active"), do: :ok
  defp plan_status("inactive"), do: :ok
  defp plan_status("completed"), do: :ok
  defp plan_status("cancelled"), do: :ok
  defp plan_status(_status), do: {:error, "invalid_plan_contract"}

  defp plan_steps(plan) do
    case Map.fetch(plan, "plan_steps") do
      {:ok, steps} when is_list(steps) ->
        validate_plan_steps(steps)

      {:ok, _steps} ->
        {:error, "invalid_plan_contract"}

      :error ->
        {:error, "invalid_plan_contract"}
    end
  end

  defp validate_plan_steps(steps) do
    case Enum.all?(steps, &valid_plan_step?/1) do
      true -> :ok
      false -> {:error, "invalid_plan_contract"}
    end
  end

  defp valid_plan_step?(step) when is_map(step) do
    case {required_text(step, "step_id", "invalid_plan_contract"),
          required_text(step, "effect_scope", "invalid_plan_contract"),
          required_string_list(step, "allowed_actions", "invalid_plan_contract")} do
      {{:ok, _step_id}, {:ok, _effect_scope}, :ok} -> true
      _invalid -> false
    end
  end

  defp valid_plan_step?(_step), do: false

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
         :ok <- plan_gate_action(action),
         {:ok, _reason} <- optional_text(gate, "reason", "invalid_plan_gate") do
      :ok
    end
  end

  defp plan_gate_action("approved"), do: :ok
  defp plan_gate_action("rejected"), do: :ok
  defp plan_gate_action("approval_required"), do: :ok
  defp plan_gate_action(_action), do: {:error, "invalid_plan_gate"}

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
         :ok <- required_list(preflight, "checks", "invalid_action_preflight"),
         :ok <- required_string_list(preflight, "blocked_checks", "invalid_action_preflight"),
         :ok <-
           required_string_list(preflight, "approval_required_checks", "invalid_action_preflight") do
      :ok
    end
  end

  defp preflight_result("passed"), do: :ok
  defp preflight_result("blocked"), do: :ok
  defp preflight_result("approval_required"), do: :ok
  defp preflight_result(_result), do: {:error, "invalid_action_preflight"}

  defp optional_policy_decision(attrs) do
    optional_contract_map(
      attrs,
      "policy_decision",
      "invalid_policy_decision",
      &validate_policy_decision/1
    )
  end

  defp validate_policy_decision(policy) do
    with {:ok, action} <- required_text(policy, "action", "invalid_policy_decision"),
         :ok <- gate_action(action),
         {:ok, _reason} <- optional_text(policy, "reason", "invalid_policy_decision") do
      :ok
    end
  end

  defp optional_consequence_prediction(attrs) do
    optional_contract_map(attrs, "prediction", "invalid_prediction", &validate_prediction/1)
  end

  defp validate_prediction(prediction) do
    with {:ok, _prediction_id} <- required_text(prediction, "prediction_id", "invalid_prediction"),
         {:ok, _effect_scope} <- optional_text(prediction, "effect_scope", "invalid_prediction"),
         :ok <- optional_number(prediction, "confidence", "invalid_prediction") do
      :ok
    end
  end

  defp optional_state_snapshot(attrs) do
    optional_contract_map(
      attrs,
      "state_snapshot",
      "invalid_state_snapshot",
      &validate_state_snapshot/1
    )
  end

  defp validate_state_snapshot(snapshot) do
    with {:ok, _snapshot_id} <- required_text(snapshot, "snapshot_id", "invalid_state_snapshot"),
         {:ok, _state_hash} <- required_text(snapshot, "state_hash", "invalid_state_snapshot") do
      :ok
    end
  end

  defp optional_state_transition(attrs) do
    optional_contract_map(
      attrs,
      "state_transition_prediction",
      "invalid_state_transition_prediction",
      &validate_state_transition/1
    )
  end

  defp validate_state_transition(transition) do
    with {:ok, _transition_id} <-
           required_text(transition, "transition_id", "invalid_state_transition_prediction"),
         :ok <-
           optional_list(transition, "expected_changes", "invalid_state_transition_prediction") do
      :ok
    end
  end

  defp optional_state_invariant(attrs) do
    optional_contract_map(
      attrs,
      "state_invariant_check",
      "invalid_state_invariant_check",
      &validate_state_invariant/1
    )
  end

  defp validate_state_invariant(invariant) do
    with {:ok, _check_id} <- required_text(invariant, "check_id", "invalid_state_invariant_check"),
         {:ok, action} <- required_text(invariant, "action", "invalid_state_invariant_check"),
         :ok <- gate_action(action),
         {:ok, _reason} <- optional_text(invariant, "reason", "invalid_state_invariant_check") do
      :ok
    end
  end

  defp gate_action("approved"), do: :ok
  defp gate_action("rejected"), do: :ok
  defp gate_action("approval_required"), do: :ok
  defp gate_action(_action), do: {:error, "invalid_policy_decision"}

  defp policy_decision(nil, policy_attrs), do: PolicyEngine.evaluate(policy_attrs)
  defp policy_decision(policy, _policy_attrs), do: policy

  defp consequence_prediction(nil, contract, plan, plan_gate, preflight) do
    case should_predict_consequence?(plan_gate, preflight) do
      true ->
        ConsequencePredictor.predict(%{
          "action_contract" => contract,
          "plan_contract" => plan,
          "action_preflight" => preflight
        })

      false ->
        %{}
    end
  end

  defp consequence_prediction(prediction, _contract, _plan, _plan_gate, _preflight),
    do: prediction

  defp should_predict_consequence?(%{"action" => "approved"}, %{"result" => result}) do
    result != "blocked"
  end

  defp should_predict_consequence?(_plan_gate, _preflight), do: false

  defp state_snapshot(nil, context, contract, plan, task) do
    WorldStateSnapshot.build(%{
      "context" => context,
      "action_contract" => contract,
      "plan_contract" => plan,
      "task" => task
    })
  end

  defp state_snapshot(snapshot, _context, _contract, _plan, _task), do: snapshot

  defp state_transition_prediction(nil, contract, prediction, snapshot) do
    case prediction do
      empty when empty == %{} ->
        %{}

      prediction ->
        StateTransitionPrediction.predict(%{
          "action_contract" => contract,
          "prediction" => prediction,
          "state_snapshot" => snapshot
        })
    end
  end

  defp state_transition_prediction(transition, _contract, _prediction, _snapshot), do: transition

  defp state_invariant_check(nil, context, contract, snapshot, transition) do
    StateInvariantCheck.evaluate(%{
      "context" => context,
      "action_contract" => contract,
      "state_snapshot" => snapshot,
      "state_transition_prediction" => transition
    })
  end

  defp state_invariant_check(invariant, _context, _contract, _snapshot, _transition),
    do: invariant

  defp final_action("rejected", _invariant_action), do: "rejected"
  defp final_action(_policy_action, "rejected"), do: "rejected"
  defp final_action("approval_required", _invariant_action), do: "approval_required"
  defp final_action(_policy_action, "approval_required"), do: "approval_required"
  defp final_action("approved", "approved"), do: "approved"
  defp final_action("approved", nil), do: "approved"
  defp final_action(_policy_action, _invariant_action), do: "rejected"

  defp decision_reason("approved", _policy, _invariant, contract) do
    "consequence_contract_approved:" <> to_string(contract["effect_scope"])
  end

  defp decision_reason("approval_required", policy, invariant, contract) do
    decision_reason(
      policy,
      invariant,
      "human_approval_required_for:" <> to_string(contract["effect_scope"])
    )
  end

  defp decision_reason(_action, policy, invariant, _contract) do
    decision_reason(policy, invariant, "consequence_gate_rejected")
  end

  defp decision_reason(policy, invariant, default) do
    case text_field(policy, "reason") do
      nil -> decision_reason_from_invariant(invariant, default)
      reason -> reason
    end
  end

  defp decision_reason_from_invariant(invariant, default) do
    case text_field(invariant, "reason") do
      nil -> default
      reason -> reason
    end
  end

  defp rejected_gate(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "gate_id" =>
        output_text(
          attrs,
          "gate_id",
          stable_id("consequence_gate", [reason, attrs])
        ),
      "action" => "rejected",
      "reason" => reason,
      "enforced" => true,
      "created_at" => Clock.iso_now()
    }
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

  defp unsupported_aliases(attrs) do
    cond do
      Map.has_key?(attrs, "contract") -> {:error, "unsupported_argument:contract"}
      Map.has_key?(attrs, "route") -> {:error, "unsupported_argument:route"}
      true -> :ok
    end
  end

  defp optional_contract_map(attrs, key, reason, validator) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) ->
        with :ok <- validator.(value) do
          {:ok, value}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, nil}
    end
  end

  defp optional_map_value(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp optional_map(map, key, reason) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
    end
  end

  defp required_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> :ok
      {:ok, _values} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_list(map, key, reason) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, values} when is_list(values) -> :ok
      {:ok, _values} -> {:error, reason}
    end
  end

  defp required_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        validate_string_list(values, reason)

      {:ok, _values} ->
        {:error, reason}

      :error ->
        {:error, reason}
    end
  end

  defp validate_string_list(values, reason) do
    case Enum.all?(values, &is_binary/1) do
      true -> :ok
      false -> {:error, reason}
    end
  end

  defp optional_number(map, key, reason) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) -> :ok
      {:ok, value} when is_float(value) -> :ok
      {:ok, _value} -> {:error, reason}
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
    case optional_text(map, key, reason) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_text(map, key, reason) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        {:ok, trim_empty(value)}

      {:ok, _value} ->
        {:error, reason}
    end
  end

  defp text_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> trim_empty(value)
      _missing -> nil
    end
  end

  defp text_field(_map, _key), do: nil

  defp output_text(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> text_default(trim_empty(value), default)
      _missing -> default
    end
  end

  defp output_text(_map, _key, default), do: default

  defp text_default(nil, default), do: default
  defp text_default(value, _default), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp trim_empty(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
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
