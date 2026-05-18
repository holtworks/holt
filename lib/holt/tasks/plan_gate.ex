defmodule Holt.Tasks.PlanGate do
  @moduledoc """
  Evaluates whether an action contract is permitted by the active plan contract.
  """

  alias Holt.Clock

  @schema_version "holt_plan_gate/v1"

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, gate_id, created_at, route, action_contract, plan_contract} ->
        decision = decision(plan_contract, action_contract, route)
        target_proof = target_proof(plan_contract, action_contract)

        %{
          "schema_version" => @schema_version,
          "gate_id" => text_default(gate_id, Clock.id("plan_gate")),
          "action" => elem(decision, 0),
          "reason" => elem(decision, 1),
          "enforced" => true,
          "plan_id" => plan_contract["plan_id"],
          "action_contract_id" => action_contract["contract_id"],
          "target_action" => action_contract["action"],
          "effect_scope" => action_contract["effect_scope"],
          "plan_step" => matching_plan_step(plan_contract, action_contract),
          "target_proof" => target_proof,
          "created_at" => text_default(created_at, Clock.iso_now())
        }
        |> compact()

      {:error, reason} ->
        rejected_gate(attrs, reason)
    end
  end

  def evaluate(_attrs), do: rejected_gate(%{}, "invalid_attrs")

  defp rejected_gate(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "gate_id" => output_text(attrs, "gate_id", Clock.id("plan_gate")),
      "action" => "rejected",
      "reason" => reason,
      "enforced" => true,
      "created_at" => output_text(attrs, "created_at", Clock.iso_now())
    }
  end

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_route(attrs),
         {:ok, gate_id} <- optional_text(attrs, "gate_id", "invalid_gate_id"),
         {:ok, created_at} <- optional_text(attrs, "created_at", "invalid_created_at"),
         {:ok, route} <- action_route(attrs),
         {:ok, action_contract} <- action_contract(attrs),
         {:ok, plan_contract} <- plan_contract(attrs) do
      {:ok, gate_id, created_at, route, action_contract, plan_contract}
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

  defp unsupported_route(attrs) do
    case Map.has_key?(attrs, "route") do
      true -> {:error, "unsupported_argument:route"}
      false -> :ok
    end
  end

  defp action_route(attrs) do
    case Map.fetch(attrs, "action_route") do
      :error ->
        {:ok, %{}}

      {:ok, route} when is_map(route) ->
        validate_action_route(route)

      {:ok, _route} ->
        {:error, "invalid_action_route"}
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
      :error ->
        {:error, "missing_action_contract"}

      {:ok, contract} when is_map(contract) ->
        with :ok <- validate_action_contract(contract) do
          {:ok, contract}
        end

      {:ok, _contract} ->
        {:error, "invalid_action_contract"}
    end
  end

  defp validate_action_contract(contract) do
    with {:ok, _contract_id} <- required_text(contract, "contract_id", "invalid_action_contract"),
         {:ok, _action} <- required_text(contract, "action", "invalid_action_contract"),
         {:ok, _effect_scope} <-
           required_text(contract, "effect_scope", "invalid_action_contract"),
         :ok <- optional_map(contract, "target_refs", "invalid_action_contract") do
      :ok
    end
  end

  defp plan_contract(attrs) do
    case Map.fetch(attrs, "plan_contract") do
      :error ->
        {:error, "missing_plan_contract"}

      {:ok, contract} when is_map(contract) ->
        with :ok <- validate_plan_contract(contract) do
          {:ok, contract}
        end

      {:ok, _contract} ->
        {:error, "invalid_plan_contract"}
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

  defp decision(plan, contract, route) do
    status = Map.get(route, "status")
    target = target_proof(plan, contract)

    cond do
      plan["status"] != "active" ->
        {"rejected", "inactive_plan_contract"}

      status == "rejected" ->
        {"rejected", route_rejection_reason(route)}

      contract["action"] in [nil, "", "unknown"] ->
        {"rejected", "action_required"}

      contract["action"] not in plan["allowed_actions"] ->
        {"rejected", "action_not_in_active_plan"}

      contract["effect_scope"] not in plan["allowed_effect_scopes"] ->
        {"rejected", "effect_scope_not_in_active_plan"}

      matching_plan_step(plan, contract) == nil ->
        {"rejected", "action_not_in_plan_step"}

      target["status"] == "blocked" ->
        {"rejected", target["reason"]}

      true ->
        {"approved", "active_plan_allows_action"}
    end
  end

  defp route_rejection_reason(%{"reason" => reason}) when reason not in [nil, ""], do: reason
  defp route_rejection_reason(_route), do: "action_route_rejected"

  defp matching_plan_step(plan, contract) do
    action = contract["action"]
    effect_scope = contract["effect_scope"]

    plan
    |> Map.fetch!("plan_steps")
    |> Enum.find(fn step ->
      plan_step_matches?(step, action, effect_scope)
    end)
    |> case do
      nil ->
        nil

      step ->
        %{
          "step_id" => step["step_id"],
          "effect_scope" => step["effect_scope"]
        }
        |> compact()
    end
  end

  defp plan_step_matches?(step, action, effect_scope) do
    case step["effect_scope"] do
      ^effect_scope -> action in step["allowed_actions"]
      _scope -> false
    end
  end

  defp target_proof(plan, contract) do
    refs = target_refs(contract)
    effect_scope = contract["effect_scope"]
    target_task_id = refs["task_id"]
    target_task_ref = refs["task_ref"]
    plan_task_id = plan["task_id"]
    plan_task_ref = plan["task_ref"]

    cond do
      same_non_empty?(target_task_id, plan_task_id) ->
        proof("allowed", "current_task", refs)

      same_non_empty?(target_task_ref, plan_task_ref) ->
        proof("allowed", "current_task", refs)

      empty_target?(target_task_id, target_task_ref) ->
        proof("allowed", "current_task_context", refs)

      effect_scope in ["read_only", "session_ephemeral"] ->
        proof("allowed", "#{effect_scope}_external_target", refs)

      true ->
        proof("blocked", "target_outside_plan_task", refs)
    end
  end

  defp target_refs(%{"target_refs" => refs}) when is_map(refs), do: refs
  defp target_refs(_contract), do: %{}

  defp proof(status, reason, refs) do
    %{
      "status" => status,
      "reason" => reason,
      "target_refs" => refs
    }
    |> compact()
  end

  defp same_non_empty?(left, right) do
    case {empty_text?(left), empty_text?(right), left == right} do
      {false, false, true} -> true
      _other -> false
    end
  end

  defp empty_target?(target_task_id, target_task_ref) do
    case {empty_text?(target_task_id), empty_text?(target_task_ref)} do
      {true, true} -> true
      _other -> false
    end
  end

  defp optional_map(map, key, reason) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_map(value) -> :ok
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
      _missing_or_invalid -> default
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

  defp empty_text?(value), do: value in [nil, ""]

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false
end
