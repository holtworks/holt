defmodule Holt.Tasks.ActionPreflight do
  @moduledoc """
  Final structured checks before a task-scoped action can execute.
  """

  alias Holt.Clock
  alias Holt.Tasks.ActionContract

  @schema_version "holt_action_preflight/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} ->
        action_contract = input.action_contract
        plan_gate = input.plan_gate
        checks = checks(input.approval_status, action_contract, plan_gate, input.action_route)
        blocked_checks = check_ids(checks, "failed")
        approval_required_checks = check_ids(checks, "approval_required")
        result = result(blocked_checks, approval_required_checks)

        %{
          "schema_version" => @schema_version,
          "preflight_id" => text_default(input.preflight_id, Clock.id("action_preflight")),
          "result" => result,
          "action" => action_contract["action"],
          "effect_scope" => action_contract["effect_scope"],
          "plan_gate" => Map.take(plan_gate, ["gate_id", "action", "reason"]),
          "checks" => checks,
          "blocked_checks" => blocked_checks,
          "approval_required_checks" => approval_required_checks,
          "simulation" => simulation(result, action_contract),
          "created_at" => text_default(input.created_at, Clock.iso_now())
        }
        |> compact()

      {:error, reason} ->
        blocked_preflight(attrs, reason)
    end
  end

  def evaluate(_attrs), do: blocked_preflight(%{}, "invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_route(attrs),
         {:ok, preflight_id} <- optional_text(attrs, "preflight_id", "invalid_preflight_id"),
         {:ok, created_at} <- optional_text(attrs, "created_at", "invalid_created_at"),
         {:ok, approval_status} <-
           optional_text(attrs, "approval_status", "invalid_approval_status"),
         {:ok, action_route} <- action_route(attrs),
         {:ok, action_contract} <- action_contract(attrs),
         {:ok, _plan_contract} <- plan_contract(attrs),
         {:ok, plan_gate} <- plan_gate(attrs) do
      {:ok,
       %{
         preflight_id: preflight_id,
         created_at: created_at,
         approval_status: approval_status,
         action_route: action_route,
         action_contract: action_contract,
         plan_gate: plan_gate
       }}
    end
  end

  defp blocked_preflight(attrs, reason) do
    check = check("action_route_accepted", "failed", reason)

    %{
      "schema_version" => @schema_version,
      "preflight_id" => output_text(attrs, "preflight_id", Clock.id("action_preflight")),
      "result" => "blocked",
      "checks" => [check],
      "blocked_checks" => [check["check_id"]],
      "approval_required_checks" => [],
      "created_at" => output_text(attrs, "created_at", Clock.iso_now())
    }
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
         :ok <- optional_recovery(contract),
         :ok <- optional_text_field(contract, "idempotency_key", "invalid_action_contract"),
         :ok <- optional_text_field(contract, "risk_level", "invalid_action_contract") do
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

  defp plan_contract(attrs) do
    case Map.fetch(attrs, "plan_contract") do
      {:ok, contract} when is_map(contract) ->
        with :ok <- validate_plan_contract(contract) do
          {:ok, contract}
        end

      {:ok, _contract} ->
        {:error, "invalid_plan_contract"}

      :error ->
        {:error, "missing_plan_contract"}
    end
  end

  defp validate_plan_contract(contract) do
    with {:ok, _plan_id} <- required_text(contract, "plan_id", "invalid_plan_contract"),
         {:ok, status} <- required_text(contract, "status", "invalid_plan_contract"),
         :ok <- plan_status(status),
         :ok <- required_string_list(contract, "allowed_actions", "invalid_plan_contract"),
         :ok <- required_string_list(contract, "allowed_effect_scopes", "invalid_plan_contract"),
         :ok <- plan_steps(contract) do
      :ok
    end
  end

  defp plan_status("active"), do: :ok
  defp plan_status("inactive"), do: :ok
  defp plan_status("completed"), do: :ok
  defp plan_status("cancelled"), do: :ok
  defp plan_status(_status), do: {:error, "invalid_plan_contract"}

  defp plan_steps(contract) do
    case Map.fetch(contract, "plan_steps") do
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

  defp checks(approval_status, action_contract, plan_gate, route) do
    [
      route_check(route),
      known_effect_scope_check(action_contract),
      plan_gate_check(plan_gate),
      target_reference_check(action_contract),
      recovery_check(action_contract),
      idempotency_check(action_contract),
      approval_check(approval_status, action_contract)
    ]
  end

  defp route_check(%{"status" => "rejected"} = route) do
    check("action_route_accepted", "failed", route_rejection_reason(route))
  end

  defp route_check(_route), do: check("action_route_accepted", "passed", "route_available")

  defp route_rejection_reason(%{"reason" => reason}) when reason not in [nil, ""], do: reason
  defp route_rejection_reason(_route), do: "action_route_rejected"

  defp known_effect_scope_check(contract) do
    case ActionContract.known_effect_scope?(contract["effect_scope"]) do
      true -> check("known_effect_scope", "passed", contract["effect_scope"])
      false -> check("known_effect_scope", "failed", "unknown_effect_scope")
    end
  end

  defp plan_gate_check(%{"action" => "approved"} = gate) do
    check("active_plan_allows_action", "passed", gate["reason"])
  end

  defp plan_gate_check(gate) do
    check("active_plan_allows_action", "failed", plan_gate_rejection_reason(gate))
  end

  defp plan_gate_rejection_reason(%{"reason" => reason}) when reason not in [nil, ""], do: reason
  defp plan_gate_rejection_reason(_gate), do: "plan_gate_rejected"

  defp target_reference_check(contract) do
    case ActionContract.mutating_effect_scope?(contract["effect_scope"]) do
      true -> mutating_target_reference_check(contract)
      false -> check("target_reference_declared", "not_applicable", "read_only_or_routed_action")
    end
  end

  defp mutating_target_reference_check(contract) do
    case map_field(contract, "target_refs") do
      refs when refs == %{} ->
        check("target_reference_declared", "failed", "missing_target_reference")

      _refs ->
        check("target_reference_declared", "passed", "target_reference_present")
    end
  end

  defp recovery_check(contract) do
    case ActionContract.mutating_effect_scope?(contract["effect_scope"]) do
      true -> mutating_recovery_check(contract)
      false -> check("recovery_declared", "not_applicable", "read_only_or_routed_action")
    end
  end

  defp mutating_recovery_check(contract) do
    recovery = map_field(contract, "recovery")

    case recovery["reversibility"] do
      value when value in [nil, "", "unknown"] ->
        check("recovery_declared", "failed", "missing_recovery_contract")

      reversibility ->
        check("recovery_declared", "passed", reversibility)
    end
  end

  defp idempotency_check(contract) do
    case ActionContract.mutating_effect_scope?(contract["effect_scope"]) do
      true -> mutating_idempotency_check(contract)
      false -> check("idempotency_declared", "not_applicable", "read_only_or_routed_action")
    end
  end

  defp mutating_idempotency_check(contract) do
    case contract["idempotency_key"] do
      value when value in [nil, ""] ->
        check("idempotency_declared", "failed", "missing_idempotency_key")

      _key ->
        check("idempotency_declared", "passed", "idempotency_key_present")
    end
  end

  defp approval_check(approval_status, contract) do
    case ActionContract.requires_approval?(contract) do
      true -> required_approval_check(approval_status)
      false -> check("approval_granted", "not_applicable", "approval_not_required")
    end
  end

  defp required_approval_check("approved"),
    do: check("approval_granted", "passed", "approval_status_approved")

  defp required_approval_check(_status),
    do: check("approval_granted", "approval_required", "human_approval_required")

  defp check(id, status, reason) do
    %{
      "check_id" => id,
      "status" => status,
      "reason" => reason
    }
    |> compact()
  end

  defp check_ids(checks, status) do
    checks
    |> Enum.filter(&(&1["status"] == status))
    |> Enum.map(& &1["check_id"])
  end

  defp result([], []), do: "passed"
  defp result([], _approval_required), do: "approval_required"
  defp result(_blocked, _approval_required), do: "blocked"

  defp simulation(result, contract) do
    %{
      "will_execute" => result == "passed",
      "requires_approval" => ActionContract.requires_approval?(contract),
      "effect_scope" => contract["effect_scope"],
      "target_refs" => map_field(contract, "target_refs")
    }
    |> compact()
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

  defp unsupported_route(attrs) do
    case Map.has_key?(attrs, "route") do
      true -> {:error, "unsupported_argument:route"}
      false -> :ok
    end
  end

  defp optional_map(map, key, reason) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> value
      _missing -> %{}
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
end
