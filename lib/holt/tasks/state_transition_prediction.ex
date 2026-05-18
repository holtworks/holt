defmodule Holt.Tasks.StateTransitionPrediction do
  @moduledoc """
  Predicts the structured state changes expected from an action.
  """

  alias Holt.Clock

  @schema_version "holt_state_transition_prediction/v1"
  @mutating_scopes ~w(task_durable agent_orchestration workspace_durable external_side_effect)

  def predict(attrs \\ %{})

  def predict(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> predict_canonical(input)
      {:error, reason} -> rejected_prediction(attrs, reason)
    end
  end

  def predict(_attrs), do: rejected_prediction(%{}, "invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, contract} <- action_contract(attrs),
         {:ok, prediction} <- prediction(attrs),
         {:ok, snapshot} <- state_snapshot(attrs) do
      {:ok, %{action_contract: contract, prediction: prediction, state_snapshot: snapshot}}
    end
  end

  defp predict_canonical(input) do
    contract = input.action_contract
    prediction = input.prediction
    snapshot = input.state_snapshot
    scope = contract["effect_scope"]
    domain = contract["target_domain"]
    target_refs = target_refs(contract)
    expected_changes = expected_changes(scope, domain, target_refs)

    %{
      "schema_version" => @schema_version,
      "transition_id" =>
        stable_id("state_transition", [
          contract["contract_id"],
          snapshot["state_hash"],
          expected_changes
        ]),
      "action_contract_id" => contract["contract_id"],
      "prediction_id" => prediction["prediction_id"],
      "state_snapshot_id" => snapshot["snapshot_id"],
      "action" => contract["action"],
      "effect_scope" => scope,
      "target_domain" => domain,
      "expected_changes" => expected_changes,
      "possible_side_effects" => possible_side_effects(scope, domain),
      "failure_modes" => list_value(prediction, "possible_failures"),
      "requires_observation" => scope in @mutating_scopes,
      "confidence" => prediction["confidence"],
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_prediction(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "transition_id" =>
        output_text(
          attrs,
          "transition_id",
          stable_id("state_transition", [reason, attrs])
        ),
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
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
         :ok <- optional_map_field(contract, "target_refs", "invalid_action_contract") do
      :ok
    end
  end

  defp prediction(attrs) do
    case Map.fetch(attrs, "prediction") do
      {:ok, prediction} when is_map(prediction) ->
        with :ok <- validate_prediction(prediction) do
          {:ok, prediction}
        end

      {:ok, _prediction} ->
        {:error, "invalid_prediction"}

      :error ->
        {:error, "missing_prediction"}
    end
  end

  defp validate_prediction(prediction) do
    with {:ok, _prediction_id} <- required_text(prediction, "prediction_id", "invalid_prediction"),
         :ok <- optional_string_list(prediction, "possible_failures", "invalid_prediction"),
         :ok <- optional_number(prediction, "confidence", "invalid_prediction") do
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
         {:ok, _state_hash} <- required_text(snapshot, "state_hash", "invalid_state_snapshot") do
      :ok
    end
  end

  defp expected_changes("read_only", domain, target_refs) do
    [
      change("read_context", "context", target_ref(domain, target_refs), "read", "none", false)
      |> Map.put("durable", false)
    ]
  end

  defp expected_changes("routed", domain, target_refs) do
    [
      change(
        "route_nested_action",
        domain,
        target_ref(domain, target_refs),
        "route",
        "nested",
        false
      )
      |> Map.put("durable", false)
    ]
  end

  defp expected_changes("task_durable", domain, target_refs) do
    [
      change(
        "update_task_state",
        domain,
        target_ref(domain, target_refs),
        "create_or_update",
        "durable",
        true
      )
    ]
  end

  defp expected_changes("agent_orchestration", domain, target_refs) do
    [
      change(
        "create_agent_work",
        domain,
        target_ref(domain, target_refs),
        "queue_or_continue",
        "durable_orchestration",
        true
      )
    ]
  end

  defp expected_changes("workspace_durable", domain, target_refs) do
    [
      change(
        "update_workspace_state",
        domain,
        target_ref(domain, target_refs),
        "write_or_execute",
        "workspace_durable",
        true
      )
    ]
  end

  defp expected_changes("external_side_effect", domain, target_refs) do
    [
      change(
        "update_external_state",
        domain,
        target_ref(domain, target_refs),
        "external_mutation",
        "external_durable",
        true
      )
    ]
  end

  defp expected_changes(_scope, domain, target_refs) do
    [
      change(
        "unknown_state_change",
        domain,
        target_ref(domain, target_refs),
        "unknown",
        "unknown",
        true
      )
    ]
  end

  defp change(code, namespace, target_ref, operation, durability, verification_required?) do
    state_key =
      [namespace, target_ref, code]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(":")

    %{
      "change_id" => stable_id("state_change", [code, namespace, target_ref]),
      "code" => code,
      "state_namespace" => namespace,
      "state_key" => state_key,
      "target_ref" => target_ref,
      "operation" => operation,
      "durability" => durability,
      "verification_required" => verification_required?
    }
    |> compact()
  end

  defp target_refs(%{"target_refs" => refs}) when is_map(refs), do: refs
  defp target_refs(_contract), do: %{}

  defp target_ref(_domain, %{"task_ref" => ref}) when ref not in [nil, ""], do: ref
  defp target_ref(_domain, %{"task_id" => id}) when id not in [nil, ""], do: id
  defp target_ref(_domain, %{"path" => path}) when path not in [nil, ""], do: path
  defp target_ref(domain, _target_refs), do: domain

  defp possible_side_effects("read_only", _domain), do: []
  defp possible_side_effects("routed", _domain), do: ["nested_contract_required"]
  defp possible_side_effects("task_durable", domain), do: ["audit_log", "#{domain}_updated"]
  defp possible_side_effects("agent_orchestration", _domain), do: ["agent_run_created"]

  defp possible_side_effects("workspace_durable", _domain),
    do: ["files_or_process_state_may_change"]

  defp possible_side_effects("external_side_effect", domain),
    do: ["#{domain}_remote_state_changed"]

  defp possible_side_effects(_scope, _domain), do: ["unknown_side_effect"]

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

  defp optional_number(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> :ok
      {:ok, value} when is_float(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
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
