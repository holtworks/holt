defmodule Holt.Tasks.ConsequencePredictor do
  @moduledoc """
  Deterministic consequence prediction for a proposed task action.
  """

  alias Holt.Clock

  @schema_version "holt_consequence_prediction/v1"

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
         {:ok, preflight} <- action_preflight(attrs) do
      {:ok, %{action_contract: contract, action_preflight: preflight}}
    end
  end

  defp predict_canonical(input) do
    contract = input.action_contract
    preflight = input.action_preflight
    scope = contract["effect_scope"]
    risk = contract["risk_level"]

    %{
      "schema_version" => @schema_version,
      "prediction_id" =>
        stable_id("prediction", [
          contract["contract_id"],
          contract["action"],
          scope,
          preflight["preflight_id"]
        ]),
      "contract_id" => contract["contract_id"],
      "action" => contract["action"],
      "effect_scope" => scope,
      "risk_level" => risk,
      "target_domain" => contract["target_domain"],
      "expected_result_status" => expected_result_status(scope),
      "expected_state_delta" => %{
        "scope" => scope,
        "target_refs" => target_refs(contract)
      },
      "possible_failures" => possible_failures(scope),
      "preflight_id" => preflight["preflight_id"],
      "preflight_result" => preflight["result"],
      "reversibility" => reversibility(contract["recovery"]),
      "confidence" => confidence(risk),
      "source" => "deterministic_action_contract/v1",
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_prediction(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "prediction_id" =>
        output_text(
          attrs,
          "prediction_id",
          stable_id("prediction", [reason, attrs])
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
         {:ok, _risk_level} <- required_text(contract, "risk_level", "invalid_action_contract"),
         {:ok, _target_domain} <-
           required_text(contract, "target_domain", "invalid_action_contract"),
         :ok <- optional_map_field(contract, "target_refs", "invalid_action_contract"),
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
         :ok <- preflight_result(result) do
      :ok
    end
  end

  defp preflight_result("passed"), do: :ok
  defp preflight_result("approval_required"), do: :ok
  defp preflight_result("blocked"), do: :ok
  defp preflight_result(_result), do: {:error, "invalid_action_preflight"}

  defp expected_result_status("read_only"), do: "ok"
  defp expected_result_status("session_ephemeral"), do: "ok"
  defp expected_result_status("routed"), do: "ok_or_nested_result"
  defp expected_result_status(_scope), do: "ok_or_awaiting_external_completion"

  defp possible_failures("read_only"), do: ["resource_missing", "permission_denied"]
  defp possible_failures("session_ephemeral"), do: ["invalid_session_state"]
  defp possible_failures("task_durable"), do: ["validation_failed", "stale_task_state"]
  defp possible_failures("agent_orchestration"), do: ["agent_unavailable", "run_not_queued"]
  defp possible_failures("workspace_durable"), do: ["command_failed", "file_conflict"]
  defp possible_failures("external_side_effect"), do: ["remote_rejected", "credential_failure"]
  defp possible_failures("routed"), do: ["nested_action_rejected", "nested_preflight_failed"]
  defp possible_failures(_scope), do: ["unknown_effect_scope", "unmodeled_side_effect"]

  defp reversibility(%{"reversibility" => reversibility}) do
    %{
      "strategy" => reversibility,
      "available" => reversibility not in ["unknown", "possibly_irreversible"]
    }
  end

  defp reversibility(_recovery), do: %{"strategy" => "unknown", "available" => false}

  defp confidence("low"), do: 0.86
  defp confidence("medium"), do: 0.72
  defp confidence("high"), do: 0.58
  defp confidence("critical"), do: 0.42
  defp confidence(_risk), do: 0.35

  defp target_refs(%{"target_refs" => refs}) when is_map(refs), do: refs
  defp target_refs(_contract), do: %{}

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

  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
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

  defp optional_map_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
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
