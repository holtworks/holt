defmodule Holt.Tasks.WorldStateSnapshot do
  @moduledoc """
  Compact structured state snapshot captured before a task action.
  """

  alias Holt.Clock

  @schema_version "holt_world_state_snapshot/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_snapshot(attrs, reason)
    end
  end

  def build(_attrs), do: rejected_snapshot(%{}, "invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, context} <- optional_context(attrs),
         {:ok, contract} <- action_contract(attrs),
         {:ok, plan} <- plan_contract(attrs),
         {:ok, task} <- optional_task(attrs) do
      {:ok, %{context: context, action_contract: contract, plan_contract: plan, task: task}}
    end
  end

  defp build_canonical(input) do
    context = input.context
    contract = input.action_contract
    plan = input.plan_contract
    task = input.task
    target_refs = target_refs(contract)

    snapshot =
      %{
        "schema_version" => @schema_version,
        "scope" => "pre_action",
        "action_contract_id" => contract["contract_id"],
        "action" => contract["action"],
        "effect_scope" => contract["effect_scope"],
        "target_domain" => contract["target_domain"],
        "task_state" => task_state(task),
        "agent_state" => agent_state(context),
        "plan_state" => plan_state(plan),
        "resource_refs" => target_refs,
        "permission_state" => permission_state(context),
        "staleness" => staleness(context),
        "captured_at" => Clock.iso_now()
      }
      |> compact()

    snapshot
    |> Map.put("snapshot_id", stable_id("world_state", [snapshot]))
    |> Map.put(
      "state_hash",
      stable_id("state_hash", [Map.drop(snapshot, ["captured_at"])])
    )
  end

  defp rejected_snapshot(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "snapshot_id" =>
        output_text(
          attrs,
          "snapshot_id",
          stable_id("world_state", [reason, attrs])
        ),
      "status" => "rejected",
      "reason" => reason,
      "captured_at" => Clock.iso_now()
    }
  end

  defp optional_context(attrs) do
    case Map.fetch(attrs, "context") do
      {:ok, context} when is_map(context) ->
        with :ok <- optional_text_field(context, "agent_id", "invalid_context"),
             :ok <- optional_text_field(context, "agent_ref", "invalid_context"),
             :ok <- optional_text_field(context, "run_id", "invalid_context"),
             :ok <- optional_text_field(context, "work_role", "invalid_context"),
             :ok <- optional_text_field(context, "approval_status", "invalid_context"),
             :ok <- optional_boolean_field(context, "autonomous", "invalid_context"),
             :ok <- optional_boolean_field(context, "verifier_context", "invalid_context"),
             :ok <- optional_boolean_field(context, "approval_already_granted", "invalid_context"),
             :ok <- optional_boolean_field(context, "policy_approval_granted", "invalid_context"),
             :ok <- optional_boolean_field(context, "stale_state_detected", "invalid_context"),
             :ok <- optional_boolean_field(context, "resource_stale", "invalid_context") do
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
         :ok <- optional_text_field(contract, "target_domain", "invalid_action_contract"),
         :ok <- optional_map_field(contract, "target_refs", "invalid_action_contract") do
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
         :ok <- optional_text_field(plan, "status", "invalid_plan_contract"),
         :ok <- optional_string_list(plan, "allowed_actions", "invalid_plan_contract"),
         :ok <- optional_string_list(plan, "allowed_effect_scopes", "invalid_plan_contract") do
      :ok
    end
  end

  defp optional_task(attrs) do
    case Map.fetch(attrs, "task") do
      {:ok, task} when is_map(task) ->
        with :ok <- optional_text_field(task, "id", "invalid_task"),
             :ok <- optional_text_field(task, "ref", "invalid_task"),
             :ok <- optional_text_field(task, "title", "invalid_task"),
             :ok <- optional_text_field(task, "status", "invalid_task"),
             :ok <- optional_text_field(task, "parent_id", "invalid_task") do
          {:ok, task}
        end

      {:ok, _task} ->
        {:error, "invalid_task"}

      :error ->
        {:ok, %{}}
    end
  end

  defp target_refs(%{"target_refs" => refs}) when is_map(refs), do: refs
  defp target_refs(_contract), do: %{}

  defp task_state(task) do
    %{
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "task_title" => task["title"],
      "task_status" => task["status"],
      "parent_task_id" => task["parent_id"]
    }
    |> compact()
  end

  defp agent_state(context) do
    %{
      "agent_id" => context["agent_id"],
      "agent_ref" => context["agent_ref"],
      "run_id" => context["run_id"],
      "work_role" => context["work_role"],
      "autonomous" => context["autonomous"]
    }
    |> compact()
  end

  defp plan_state(plan) do
    %{
      "plan_id" => plan["plan_id"],
      "allowed_actions" => list_value(plan, "allowed_actions"),
      "allowed_effect_scopes" => list_value(plan, "allowed_effect_scopes"),
      "status" => plan["status"]
    }
    |> compact()
  end

  defp permission_state(context) do
    %{
      "approval_granted" => approval_granted?(context),
      "approval_source" => approval_source(context),
      "verifier_context" => verifier_context?(context)
    }
    |> compact()
  end

  defp staleness(context) do
    markers =
      [
        stale_marker(context, "stale_state_detected"),
        stale_marker(context, "resource_stale")
      ]
      |> Enum.reject(&is_nil/1)

    %{
      "stale" => markers != [],
      "markers" => markers
    }
    |> compact()
  end

  defp approval_granted?(context) do
    case approval_source(context) do
      nil -> false
      _source -> true
    end
  end

  defp approval_source(context) do
    cond do
      context["approval_already_granted"] == true -> "action_context"
      context["policy_approval_granted"] == true -> "policy_context"
      context["approval_status"] == "approved" -> "approval_status"
      true -> nil
    end
  end

  defp verifier_context?(%{"work_role" => "verifier"}), do: true
  defp verifier_context?(%{"verifier_context" => true}), do: true
  defp verifier_context?(_context), do: false

  defp stale_marker(context, marker) do
    case context[marker] do
      true -> marker
      _value -> nil
    end
  end

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

  defp optional_map_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
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
    case Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
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
