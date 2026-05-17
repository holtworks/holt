defmodule HoltWorks.Tasks.PlanGate do
  @moduledoc """
  Evaluates whether an action contract is permitted by the active plan contract.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.{ActionContract, PlanContract}

  @schema_version "holtworks_plan_gate/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    route = normalize_map(value(attrs, "task_tool_route") || value(attrs, "route"))
    action_contract = action_contract(attrs, route)
    plan_contract = plan_contract(attrs)
    decision = decision(plan_contract, action_contract, route)
    target_proof = target_proof(plan_contract, action_contract)

    %{
      "schema_version" => @schema_version,
      "gate_id" => optional_text(attrs, "gate_id", Clock.id("plan_gate")),
      "action" => elem(decision, 0),
      "reason" => elem(decision, 1),
      "enforced" => true,
      "plan_id" => plan_contract["plan_id"],
      "action_contract_id" => action_contract["contract_id"],
      "tool_name" => action_contract["tool_name"],
      "effect_scope" => action_contract["effect_scope"],
      "plan_step" => matching_plan_step(plan_contract, action_contract),
      "target_proof" => target_proof,
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

  defp decision(plan, contract, route) do
    status = value(route, "status")
    target = target_proof(plan, contract)

    cond do
      plan["status"] != "active" ->
        {"rejected", "inactive_plan_contract"}

      status == "rejected" ->
        {"rejected", value(route, "reason") || "tool_route_rejected"}

      contract["tool_name"] in [nil, "", "unknown"] ->
        {"rejected", "tool_name_required"}

      contract["tool_name"] not in normalize_string_list(plan["allowed_tools"]) ->
        {"rejected", "tool_not_in_active_plan"}

      contract["effect_scope"] not in normalize_string_list(plan["allowed_effect_scopes"]) ->
        {"rejected", "effect_scope_not_in_active_plan"}

      matching_plan_step(plan, contract) == nil ->
        {"rejected", "tool_not_in_plan_step"}

      target["status"] == "blocked" ->
        {"rejected", target["reason"]}

      true ->
        {"approved", "active_plan_allows_action"}
    end
  end

  defp matching_plan_step(plan, contract) do
    tool_name = contract["tool_name"]
    effect_scope = contract["effect_scope"]

    plan
    |> Map.get("plan_steps", [])
    |> Enum.find(fn step ->
      tool_name in normalize_string_list(step["allowed_tools"]) and
        step["effect_scope"] == effect_scope
    end)
    |> case do
      nil ->
        nil

      step ->
        %{
          "step_id" => step["step_id"],
          "effect_scope" => step["effect_scope"]
        }
        |> reject_empty()
    end
  end

  defp target_proof(plan, contract) do
    refs = normalize_map(contract["target_refs"])
    effect_scope = contract["effect_scope"]
    target_task_id = refs["task_id"]
    target_task_ref = refs["task_ref"]
    plan_task_id = plan["task_id"]
    plan_task_ref = plan["task_ref"]

    cond do
      same_non_empty?(target_task_id, plan_task_id) or
          same_non_empty?(target_task_ref, plan_task_ref) ->
        proof("allowed", "current_task", refs)

      target_task_id in [nil, ""] and target_task_ref in [nil, ""] ->
        proof("allowed", "current_task_context", refs)

      effect_scope in ["read_only", "session_ephemeral"] ->
        proof("allowed", "#{effect_scope}_external_target", refs)

      true ->
        proof("blocked", "target_outside_plan_task", refs)
    end
  end

  defp proof(status, reason, refs) do
    %{
      "status" => status,
      "reason" => reason,
      "target_refs" => refs
    }
    |> reject_empty()
  end

  defp same_non_empty?(left, right) do
    left not in [nil, ""] and right not in [nil, ""] and left == right
  end

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    text = value |> to_string() |> String.trim()

    if text == "" do
      []
    else
      text
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp normalize_map(value) when is_map(value), do: string_keys(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp optional_text(attrs, key, default)

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
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
