defmodule Holt.Tasks.MetaLearningLoop do
  @moduledoc """
  Meta-learning recommendations from measured prediction, repair, and verifier outcomes.

  This module does not rewrite policy. It produces explicit proposed updates
  that can be reviewed, persisted, and applied by a policy owner.
  """

  alias Holt.Clock

  @schema_version "holt_meta_learning_snapshot/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, calibrations} <- records_field(attrs, "outcome_calibrations"),
         :ok <- validate_calibrations(calibrations),
         {:ok, repairs} <- records_field(attrs, "repair_effectiveness"),
         :ok <- validate_repairs(repairs),
         {:ok, verifier_quality} <- records_field(attrs, "verifier_quality"),
         :ok <- validate_verifier_quality(verifier_quality),
         {:ok, prior_lessons} <- records_field(attrs, "prior_lessons"),
         :ok <- validate_prior_lessons(prior_lessons) do
      recommendations =
        []
        |> add_calibration_recommendations(calibrations)
        |> add_repair_recommendations(repairs)
        |> add_verifier_recommendations(verifier_quality)
        |> add_lesson_recommendations(prior_lessons)
        |> Enum.reverse()

      %{
        "schema_version" => @schema_version,
        "snapshot_id" =>
          stable_id("meta_learning", [
            Enum.map(calibrations, & &1["calibration_id"]),
            Enum.map(repairs, & &1["repair_id"]),
            Enum.map(verifier_quality, & &1["verifier_agent_id"]),
            Enum.map(prior_lessons, & &1["task_pattern_key"])
          ]),
        "metrics" => metrics(calibrations, repairs, verifier_quality, prior_lessons),
        "recommendations" => recommendations,
        "proposed_policy_updates" => proposed_policy_updates(recommendations),
        "generated_at" => Clock.iso_now()
      }
      |> reject_empty()
    else
      {:error, reason} -> rejected_snapshot(reason)
    end
  end

  def build(_attrs), do: rejected_snapshot("invalid_attrs")

  defp rejected_snapshot(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp add_calibration_recommendations(acc, calibrations) do
    calibrations
    |> Enum.reject(&matched?/1)
    |> Enum.group_by(& &1["action"])
    |> Enum.reduce(acc, fn {action_name, items}, list ->
      if action_name in [nil, ""] do
        list
      else
        [
          recommendation(
            "prediction_contract",
            action_name,
            "raise_verification_attention",
            "repeated_prediction_mismatch",
            length(items)
          )
          | list
        ]
      end
    end)
  end

  defp add_repair_recommendations(acc, repairs) do
    repairs
    |> Enum.filter(&(&1["effectiveness_status"] in ["pending_repair", "escalated"]))
    |> Enum.group_by(& &1["source_action"])
    |> Enum.reduce(acc, fn {action_name, items}, list ->
      if action_name in [nil, ""] do
        list
      else
        [
          recommendation(
            "repair_policy",
            action_name,
            "tighten_retry_or_escalation_contract",
            "repair_not_resolved",
            length(items)
          )
          | list
        ]
      end
    end)
  end

  defp add_verifier_recommendations(acc, verifier_quality) do
    Enum.reduce(verifier_quality, acc, fn quality, list ->
      accuracy = number_field(quality, "accuracy", 1.0)

      if accuracy < 0.6 and quality["verifier_agent_id"] not in [nil, ""] do
        [
          recommendation(
            "verifier_assignment",
            quality["verifier_agent_id"],
            "deprioritize_until_recalibrated",
            "low_verifier_accuracy",
            integer_field(quality, "calibration_count", 0)
          )
          | list
        ]
      else
        list
      end
    end)
  end

  defp add_lesson_recommendations(acc, prior_lessons) do
    Enum.reduce(prior_lessons, acc, fn lesson, list ->
      mismatch_count = integer_field(lesson, "application_mismatch_count", 0)

      if mismatch_count > 0 do
        [
          recommendation(
            "task_pattern_memory",
            lesson["task_pattern_key"],
            "review_lesson_applicability",
            "lesson_application_mismatch",
            mismatch_count
          )
          | list
        ]
      else
        list
      end
    end)
  end

  defp recommendation(target_type, target_id, action, reason_code, evidence_count) do
    %{
      "recommendation_id" => stable_id("meta_rec", [target_type, target_id, action, reason_code]),
      "target_type" => target_type,
      "target_id" => target_id,
      "action" => action,
      "reason_code" => reason_code,
      "evidence_count" => evidence_count,
      "confidence" => confidence(evidence_count)
    }
    |> reject_empty()
  end

  defp proposed_policy_updates(recommendations) do
    Enum.map(recommendations, fn rec ->
      %{
        "target_type" => rec["target_type"],
        "target_id" => rec["target_id"],
        "proposed_change" => rec["action"],
        "reason_code" => rec["reason_code"],
        "requires_human_review" => true
      }
    end)
  end

  defp metrics(calibrations, repairs, verifier_quality, prior_lessons) do
    mismatches = Enum.count(calibrations, &(not matched?(&1)))
    repair_required = Enum.count(repairs, &repair_required?/1)

    %{
      "outcome_calibration_count" => length(calibrations),
      "prediction_mismatch_count" => mismatches,
      "repair_effectiveness_count" => length(repairs),
      "repair_required_count" => repair_required,
      "verifier_quality_count" => length(verifier_quality),
      "prior_lesson_count" => length(prior_lessons)
    }
  end

  defp confidence(count) when count >= 5, do: 0.85
  defp confidence(count) when count >= 3, do: 0.7
  defp confidence(count) when count >= 1, do: 0.55
  defp confidence(_count), do: 0.4

  defp records_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_list(value) -> canonical_records(value, key)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, []}
    end
  end

  defp matched?(%{"matched" => true}), do: true
  defp matched?(_calibration), do: false

  defp repair_required?(%{"repair_required" => true}), do: true
  defp repair_required?(_repair), do: false

  defp integer_field(map, key, default) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _value -> default
    end
  end

  defp number_field(map, key, default) do
    case Map.get(map, key) do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      _value -> default
    end
  end

  defp canonical_records(records, key) do
    Enum.reduce_while(records, {:ok, []}, fn
      record, {:ok, acc} when is_map(record) ->
        case canonical_nested_map(record, key) do
          :ok -> {:cont, {:ok, [record | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _record, {:ok, _acc} ->
        {:halt, {:error, "invalid_field:#{key}"}}
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_calibrations(records) do
    validate_records(records, "outcome_calibrations", [
      {"calibration_id", :string},
      {"action", :string},
      {"matched", :boolean}
    ])
  end

  defp validate_repairs(records) do
    validate_records(records, "repair_effectiveness", [
      {"repair_id", :string},
      {"source_action", :string},
      {"effectiveness_status", :string},
      {"repair_required", :boolean}
    ])
  end

  defp validate_verifier_quality(records) do
    validate_records(records, "verifier_quality", [
      {"verifier_agent_id", :string},
      {"accuracy", :number},
      {"calibration_count", :integer}
    ])
  end

  defp validate_prior_lessons(records) do
    validate_records(records, "prior_lessons", [
      {"task_pattern_key", :string},
      {"application_mismatch_count", :integer}
    ])
  end

  defp validate_records(records, field, rules) do
    if Enum.all?(records, &valid_record?(&1, rules)) do
      :ok
    else
      {:error, "invalid_field:#{field}"}
    end
  end

  defp valid_record?(record, rules) do
    Enum.all?(rules, fn {key, type} ->
      case Map.fetch(record, key) do
        {:ok, value} -> valid_type?(value, type)
        :error -> true
      end
    end)
  end

  defp valid_type?(value, :string), do: is_binary(value) and String.trim(value) != ""
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :number), do: number_value?(value)

  defp number_value?(value) when is_integer(value), do: true
  defp number_value?(value) when is_float(value), do: true
  defp number_value?(_value), do: false

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp canonical_nested_map(map, key) do
    if canonical_value?(map) do
      :ok
    else
      {:error, "invalid_field:#{key}"}
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

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false

  defp stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end
end
