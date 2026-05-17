defmodule Holt.Tasks.ConsequencePredictor do
  @moduledoc """
  Deterministic consequence prediction for a proposed task action.
  """

  alias Holt.Clock
  alias Holt.Tasks.{ActionContract, RuntimeContracts}

  @schema_version "holtworks_consequence_prediction/v1"

  def predict(attrs \\ %{})

  def predict(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    contract = action_contract(attrs)
    preflight = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "action_preflight"))
    scope = contract["effect_scope"] || "unknown"
    risk = contract["risk_level"] || "unknown"

    %{
      "schema_version" => @schema_version,
      "prediction_id" =>
        RuntimeContracts.stable_id("prediction", [
          contract["contract_id"],
          contract["tool_name"],
          scope,
          RuntimeContracts.value(preflight, "preflight_id")
        ]),
      "contract_id" => contract["contract_id"],
      "tool_name" => contract["tool_name"],
      "effect_scope" => scope,
      "risk_level" => risk,
      "target_domain" => contract["target_domain"],
      "expected_result_status" => expected_result_status(scope),
      "expected_state_delta" => %{
        "scope" => scope,
        "target_refs" => contract["target_refs"] || %{}
      },
      "possible_failures" => possible_failures(scope),
      "preflight_id" => preflight["preflight_id"],
      "preflight_result" => preflight["result"],
      "reversibility" => reversibility(contract["recovery"]),
      "confidence" => confidence(risk),
      "source" => "deterministic_action_contract/v1",
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def predict(_attrs), do: predict(%{})

  defp action_contract(attrs) do
    case RuntimeContracts.value(attrs, "action_contract") ||
           RuntimeContracts.value(attrs, "contract") do
      contract when is_map(contract) -> RuntimeContracts.string_keys(contract)
      _missing -> ActionContract.build(attrs)
    end
  end

  defp expected_result_status("read_only"), do: "ok"
  defp expected_result_status("session_ephemeral"), do: "ok"
  defp expected_result_status("routed"), do: "ok_or_nested_result"
  defp expected_result_status("unknown"), do: "blocked_before_execution"
  defp expected_result_status(_scope), do: "ok_or_awaiting_external_completion"

  defp possible_failures("read_only"), do: ["resource_missing", "permission_denied"]
  defp possible_failures("session_ephemeral"), do: ["invalid_session_state"]
  defp possible_failures("task_durable"), do: ["validation_failed", "stale_task_state"]
  defp possible_failures("agent_orchestration"), do: ["agent_unavailable", "run_not_queued"]
  defp possible_failures("workspace_durable"), do: ["command_failed", "file_conflict"]
  defp possible_failures("external_side_effect"), do: ["remote_rejected", "credential_failure"]
  defp possible_failures("routed"), do: ["nested_tool_rejected", "nested_preflight_failed"]
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
end
