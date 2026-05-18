defmodule Holt.Tasks.VerifierCalibration do
  @moduledoc """
  Calibration record for verifier quality.

  Verifier assignment proves independence and capability. Calibration measures
  whether the verifier's verdict matched later structured outcome signals so
  future assignment can prefer stronger verifiers.
  """

  alias Holt.Clock

  @schema_version "holt_verifier_calibration/v1"
  @unsupported_keys ~w(verdict)
  @severe_blockers ~w(
    severe_prediction_error
    route_verification_review_not_satisfied
    child_agent_contract_incomplete
  )

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, input} <- input(attrs) do
      build_canonical(input)
    else
      {:error, reason} -> rejected_calibration(attrs, reason)
    end
  end

  def build(_attrs), do: rejected_calibration(%{}, "invalid_attrs")

  defp input(attrs) do
    with {:ok, assignment} <- assignment_field(attrs),
         {:ok, selected_verifier} <- selected_verifier_field(assignment),
         {:ok, evaluation} <- evaluation_field(attrs),
         {:ok, outcome_calibration} <- outcome_calibration_field(attrs),
         {:ok, work_graph_gate} <- work_graph_gate_field(attrs),
         {:ok, missed_failure_kinds} <-
           optional_string_list(attrs, "missed_failure_kinds", "invalid_missed_failure_kinds"),
         {:ok, later_auto_finish_allowed?} <-
           optional_boolean(
             attrs,
             "later_auto_finish_allowed",
             false,
             "invalid_later_auto_finish_allowed"
           ),
         {:ok, verifier_agent_id} <-
           optional_text(attrs, "verifier_agent_id", "invalid_verifier_agent_id"),
         {:ok, verifier_route_id} <-
           optional_text(attrs, "verifier_route_id", "invalid_verifier_route_id"),
         {:ok, verifier_child_contract_id} <-
           optional_text(
             attrs,
             "verifier_child_contract_id",
             "invalid_verifier_child_contract_id"
           ),
         {:ok, verifier_action_call_id} <-
           optional_text(attrs, "verifier_action_call_id", "invalid_verifier_action_call_id"),
         {:ok, later_outcome} <- optional_text(attrs, "later_outcome", "invalid_later_outcome") do
      {:ok,
       %{
         assignment: assignment,
         selected_verifier: selected_verifier,
         evaluation: evaluation,
         outcome_calibration: outcome_calibration,
         work_graph_gate: work_graph_gate,
         missed_failure_kinds: missed_failure_kinds,
         later_auto_finish_allowed?: later_auto_finish_allowed?,
         verifier_agent_id: verifier_agent_id,
         verifier_route_id: verifier_route_id,
         verifier_child_contract_id: verifier_child_contract_id,
         verifier_action_call_id: verifier_action_call_id,
         later_outcome: later_outcome
       }}
    end
  end

  defp build_canonical(input) do
    verdict = verifier_verdict(input.evaluation)
    later_outcome = later_outcome(input, verdict)
    missed_failure_kinds = missed_failure_kinds(input)

    %{
      "schema_version" => @schema_version,
      "calibration_id" =>
        stable_id("verifier_calibration", [
          input.assignment["assignment_id"],
          input.verifier_agent_id,
          input.verifier_route_id,
          input.verifier_child_contract_id,
          verdict,
          later_outcome
        ]),
      "verifier_agent_id" => input.verifier_agent_id,
      "verifier_assignment_id" => input.assignment["assignment_id"],
      "verifier_route_id" => input.verifier_route_id,
      "verifier_child_contract_id" => input.verifier_child_contract_id,
      "verifier_action_call_id" => input.verifier_action_call_id,
      "work_product_ref" => input.assignment["work_product_ref"],
      "verdict" => verdict,
      "later_outcome" => later_outcome,
      "accuracy_delta" => accuracy_delta(later_outcome),
      "missed_failure_kinds" => missed_failure_kinds,
      "recommended_future_assignment_policy" =>
        recommended_future_assignment_policy(later_outcome, missed_failure_kinds),
      "assignment_result" => input.assignment["assignment_result"],
      "selected_verifier" => input.selected_verifier,
      "completion_decision" => input.evaluation["completion_decision"],
      "verification_status" => input.evaluation["verification_status"],
      "can_finish" => input.evaluation["can_finish"],
      "required_reviewers" => Map.get(input.evaluation, "required_reviewers", []),
      "outcome_source" => outcome_source(input),
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_calibration(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "calibration_id" => calibration_id(attrs, reason),
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp calibration_id(attrs, reason) do
    case text_value(attrs, "calibration_id") do
      nil -> stable_id("verifier_calibration", [reason, attrs])
      id -> id
    end
  end

  defp verifier_verdict(evaluation) do
    completion_decision = evaluation["completion_decision"]
    verification_status = evaluation["verification_status"]
    can_finish? = Map.get(evaluation, "can_finish") == true
    required_reviewers = Map.get(evaluation, "required_reviewers", [])

    cond do
      approved_verdict?(completion_decision, verification_status, can_finish?) ->
        "approved"

      rejected_verdict?(completion_decision, verification_status) ->
        "rejected"

      human_review_verdict?(completion_decision, required_reviewers) ->
        "human_review_required"

      true ->
        "unknown"
    end
  end

  defp later_outcome(input, verdict) do
    cond do
      input.later_outcome not in [nil, ""] ->
        input.later_outcome

      missed_failure?(verdict, input.outcome_calibration, input.work_graph_gate) ->
        "missed_failure"

      false_block?(input, verdict) ->
        "false_block"

      verdict == "human_review_required" ->
        "unresolved"

      matched_outcome?(verdict, input.evaluation) ->
        "matched"

      true ->
        "unresolved"
    end
  end

  defp missed_failure_kinds(%{missed_failure_kinds: explicit}) when explicit != [], do: explicit

  defp missed_failure_kinds(input) do
    calibration_effects = Map.get(input.outcome_calibration, "missed_effects", [])

    blockers =
      input.work_graph_gate
      |> Map.get("blockers", [])
      |> Enum.map(& &1["code"])

    Enum.uniq(calibration_effects ++ blockers)
  end

  defp approved_verdict?("auto_finish_allowed", "passed", true), do: true
  defp approved_verdict?(_completion_decision, _verification_status, _can_finish?), do: false

  defp rejected_verdict?(completion_decision, verification_status) do
    cond do
      completion_decision in ["fix_required", "rejected"] -> true
      verification_status == "failed" -> true
      true -> false
    end
  end

  defp human_review_verdict?(completion_decision, required_reviewers) do
    cond do
      completion_decision == "human_review_required" -> true
      required_reviewers != [] -> true
      true -> false
    end
  end

  defp missed_failure?("approved", outcome_calibration, work_graph_gate) do
    cond do
      Map.get(outcome_calibration, "matched") == false -> true
      severe_work_graph_blockers?(work_graph_gate) -> true
      true -> false
    end
  end

  defp missed_failure?(_verdict, _outcome_calibration, _work_graph_gate), do: false

  defp false_block?(input, verdict) when verdict in ["rejected", "human_review_required"] do
    input.later_auto_finish_allowed? == true
  end

  defp false_block?(_input, _verdict), do: false

  defp matched_outcome?(verdict, evaluation) when verdict in ["approved", "rejected"] do
    evaluation["completion_decision"] not in [nil, ""]
  end

  defp matched_outcome?(_verdict, _evaluation), do: false

  defp severe_work_graph_blockers?(work_graph_gate) do
    work_graph_gate
    |> Map.get("blockers", [])
    |> Enum.any?(&(&1["code"] in @severe_blockers))
  end

  defp accuracy_delta("matched"), do: 0.04
  defp accuracy_delta("missed_failure"), do: -0.18
  defp accuracy_delta("false_block"), do: -0.1
  defp accuracy_delta(_later_outcome), do: 0.0

  defp recommended_future_assignment_policy("matched", _missed_failure_kinds),
    do: "keep_current_verifier_eligible"

  defp recommended_future_assignment_policy("missed_failure", []) do
    "downrank_verifier_until_more_successes"
  end

  defp recommended_future_assignment_policy("missed_failure", _missed_failure_kinds) do
    "require_second_verifier_for_matching_failure_kinds"
  end

  defp recommended_future_assignment_policy("false_block", _missed_failure_kinds),
    do: "downrank_for_low_risk_or_time_sensitive_work"

  defp recommended_future_assignment_policy(_later_outcome, _missed_failure_kinds),
    do: "keep_baseline_until_outcome_resolved"

  defp outcome_source(input) do
    cond do
      input.later_outcome not in [nil, ""] ->
        "explicit_later_outcome"

      map_size(input.outcome_calibration) > 0 ->
        "outcome_calibration"

      map_size(input.work_graph_gate) > 0 ->
        "work_graph_gate"

      true ->
        "objective_evaluation"
    end
  end

  defp assignment_field(attrs) do
    with {:ok, assignment} <-
           optional_map(attrs, "verifier_assignment", "invalid_verifier_assignment"),
         {:ok, assignment} <-
           optional_text_field(assignment, "assignment_id", "invalid_verifier_assignment"),
         {:ok, assignment} <-
           optional_text_field(assignment, "work_product_ref", "invalid_verifier_assignment"),
         {:ok, assignment} <-
           optional_text_field(assignment, "assignment_result", "invalid_verifier_assignment") do
      {:ok, assignment}
    end
  end

  defp selected_verifier_field(assignment) do
    with {:ok, selected} <-
           optional_map(assignment, "selected_verifier", "invalid_verifier_assignment"),
         {:ok, selected} <-
           optional_text_field(selected, "agent_id", "invalid_verifier_assignment"),
         {:ok, selected} <-
           optional_text_field(selected, "agent_ref", "invalid_verifier_assignment"),
         {:ok, selected} <- optional_text_field(selected, "handle", "invalid_verifier_assignment"),
         {:ok, selected} <- optional_text_field(selected, "name", "invalid_verifier_assignment") do
      {:ok, selected}
    end
  end

  defp evaluation_field(attrs) do
    with {:ok, evaluation} <- optional_map(attrs, "evaluation", "invalid_evaluation"),
         {:ok, evaluation} <-
           optional_text_field(evaluation, "completion_decision", "invalid_evaluation"),
         {:ok, evaluation} <-
           optional_text_field(evaluation, "verification_status", "invalid_evaluation"),
         {:ok, evaluation} <-
           optional_boolean_field(evaluation, "can_finish", "invalid_evaluation"),
         {:ok, reviewers} <-
           optional_string_list(evaluation, "required_reviewers", "invalid_evaluation") do
      {:ok, Map.put(evaluation, "required_reviewers", reviewers) |> compact()}
    end
  end

  defp outcome_calibration_field(attrs) do
    with {:ok, calibration} <-
           optional_map(attrs, "outcome_calibration", "invalid_outcome_calibration"),
         {:ok, calibration} <-
           optional_boolean_field(calibration, "matched", "invalid_outcome_calibration"),
         {:ok, missed_effects} <-
           optional_string_list(calibration, "missed_effects", "invalid_outcome_calibration") do
      {:ok, Map.put(calibration, "missed_effects", missed_effects) |> compact()}
    end
  end

  defp work_graph_gate_field(attrs) do
    with {:ok, gate} <- optional_map(attrs, "work_graph_gate", "invalid_work_graph_gate"),
         {:ok, gate} <- optional_text_field(gate, "status", "invalid_work_graph_gate"),
         {:ok, blockers} <- blockers_field(gate) do
      {:ok, Map.put(gate, "blockers", blockers) |> compact()}
    end
  end

  defp blockers_field(gate) do
    case Map.fetch(gate, "blockers") do
      {:ok, blockers} when is_list(blockers) -> blockers(blockers)
      {:ok, _blockers} -> {:error, "invalid_work_graph_gate"}
      :error -> {:ok, []}
    end
  end

  defp blockers(blockers) do
    blockers
    |> Enum.reduce_while({:ok, []}, fn
      blocker, {:ok, acc} when is_map(blocker) ->
        case optional_text_field(blocker, "code", "invalid_work_graph_gate") do
          {:ok, %{"code" => _code} = normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:ok, _missing_code} -> {:halt, {:error, "invalid_work_graph_gate"}}
          error -> {:halt, error}
        end

      _blocker, {:ok, _acc} ->
        {:halt, {:error, "invalid_work_graph_gate"}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp unsupported_arguments(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(&(&1 in @unsupported_keys))
    |> unsupported_key_error()
  end

  defp unsupported_key_error(nil), do: :ok
  defp unsupported_key_error(key), do: {:error, "unsupported_argument:" <> key}

  defp optional_map(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp optional_boolean(attrs, key, default, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, default}
    end
  end

  defp optional_boolean_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, Map.put(map, key, value)}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, map}
    end
  end

  defp optional_text(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, nil}
    end
  end

  defp optional_text_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, Map.put(map, key, text)}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, map}
    end
  end

  defp optional_string_list(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, values} -> string_list(values, reason)
      :error -> {:ok, []}
    end
  end

  defp string_list(values, reason) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:halt, {:error, reason}}
          text -> {:cont, {:ok, [text | acc]}}
        end

      _value, {:ok, _acc} ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.uniq(Enum.reverse(normalized))}
      error -> error
    end
  end

  defp string_list(_values, reason), do: {:error, reason}

  defp text_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp text_value(_map, _key), do: nil

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

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
