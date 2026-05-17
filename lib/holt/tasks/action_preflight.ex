defmodule Holt.Tasks.ActionPreflight do
  @moduledoc """
  Final structured checks before a task-scoped action can execute.
  """

  alias Holt.Clock
  alias Holt.Tasks.{ActionContract, PlanContract, PlanGate}

  @schema_version "holtworks_action_preflight/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    route = normalize_map(value(attrs, "task_tool_route") || value(attrs, "route"))
    action_contract = action_contract(attrs, route)
    plan_contract = plan_contract(attrs)
    plan_gate = plan_gate(attrs, action_contract, plan_contract, route)
    checks = checks(attrs, action_contract, plan_gate, route)
    blocked_checks = check_ids(checks, "failed")
    approval_required_checks = check_ids(checks, "approval_required")
    result = result(blocked_checks, approval_required_checks)

    %{
      "schema_version" => @schema_version,
      "preflight_id" => optional_text(attrs, "preflight_id", Clock.id("action_preflight")),
      "result" => result,
      "tool_name" => action_contract["tool_name"],
      "effect_scope" => action_contract["effect_scope"],
      "plan_gate" => Map.take(plan_gate, ["gate_id", "action", "reason"]),
      "checks" => checks,
      "blocked_checks" => blocked_checks,
      "approval_required_checks" => approval_required_checks,
      "simulation" => simulation(result, action_contract),
      "created_at" => optional_text(attrs, "created_at", Clock.iso_now())
    }
    |> reject_empty()
  end

  def evaluate(_attrs), do: evaluate(%{})

  defp action_contract(attrs, route) do
    case value(attrs, "action_contract") || value(route, "action_contract") do
      contract when is_map(contract) -> string_keys(contract)
      _missing -> ActionContract.build(attrs)
    end
  end

  defp plan_contract(attrs) do
    case value(attrs, "plan_contract") do
      contract when is_map(contract) -> string_keys(contract)
      _missing -> PlanContract.build(attrs)
    end
  end

  defp plan_gate(attrs, action_contract, plan_contract, route) do
    case value(attrs, "plan_gate") do
      gate when is_map(gate) ->
        string_keys(gate)

      _missing ->
        PlanGate.evaluate(%{
          "action_contract" => action_contract,
          "plan_contract" => plan_contract,
          "task_tool_route" => route
        })
    end
  end

  defp checks(attrs, action_contract, plan_gate, route) do
    [
      route_check(route),
      known_effect_scope_check(action_contract),
      plan_gate_check(plan_gate),
      target_reference_check(action_contract),
      recovery_check(action_contract),
      idempotency_check(action_contract),
      approval_check(attrs, action_contract)
    ]
  end

  defp route_check(route) do
    case route["status"] do
      "rejected" -> check("tool_route_accepted", "failed", route["reason"])
      _status -> check("tool_route_accepted", "passed", "route_available")
    end
  end

  defp known_effect_scope_check(contract) do
    if ActionContract.known_effect_scope?(contract["effect_scope"]) do
      check("known_effect_scope", "passed", contract["effect_scope"])
    else
      check("known_effect_scope", "failed", "unknown_effect_scope")
    end
  end

  defp plan_gate_check(%{"action" => "approved"} = gate) do
    check("active_plan_allows_action", "passed", gate["reason"])
  end

  defp plan_gate_check(gate) do
    check("active_plan_allows_action", "failed", gate["reason"] || "plan_gate_rejected")
  end

  defp target_reference_check(contract) do
    if ActionContract.mutating_effect_scope?(contract["effect_scope"]) do
      refs = normalize_map(contract["target_refs"])

      if refs == %{} do
        check("target_reference_declared", "failed", "missing_target_reference")
      else
        check("target_reference_declared", "passed", "target_reference_present")
      end
    else
      check("target_reference_declared", "not_applicable", "read_only_or_routed_action")
    end
  end

  defp recovery_check(contract) do
    if ActionContract.mutating_effect_scope?(contract["effect_scope"]) do
      recovery = normalize_map(contract["recovery"])

      if recovery["reversibility"] in [nil, "", "unknown"] do
        check("recovery_declared", "failed", "missing_recovery_contract")
      else
        check("recovery_declared", "passed", recovery["reversibility"])
      end
    else
      check("recovery_declared", "not_applicable", "read_only_or_routed_action")
    end
  end

  defp idempotency_check(contract) do
    if ActionContract.mutating_effect_scope?(contract["effect_scope"]) do
      if contract["idempotency_key"] in [nil, ""] do
        check("idempotency_declared", "failed", "missing_idempotency_key")
      else
        check("idempotency_declared", "passed", "idempotency_key_present")
      end
    else
      check("idempotency_declared", "not_applicable", "read_only_or_routed_action")
    end
  end

  defp approval_check(attrs, contract) do
    if ActionContract.requires_approval?(contract) do
      case optional_text(attrs, "approval_status") do
        "approved" -> check("approval_granted", "passed", "approval_status_approved")
        _status -> check("approval_granted", "approval_required", "human_approval_required")
      end
    else
      check("approval_granted", "not_applicable", "approval_not_required")
    end
  end

  defp check(id, status, reason) do
    %{
      "check_id" => id,
      "status" => status,
      "reason" => reason
    }
    |> reject_empty()
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
      "target_refs" => normalize_map(contract["target_refs"])
    }
    |> reject_empty()
  end

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp optional_text(attrs, key, default \\ nil)

  defp optional_text(attrs, key, default) when is_map(attrs) do
    case Map.get(attrs, key, default) do
      nil ->
        default

      value ->
        text = value |> to_string() |> String.trim()
        if text == "", do: default, else: text
    end
  end

  defp optional_text(_attrs, _key, default), do: default

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp string_keys(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: string_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end
end
