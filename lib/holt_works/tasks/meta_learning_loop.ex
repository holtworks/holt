defmodule HoltWorks.Tasks.MetaLearningLoop do
  @moduledoc """
  Meta-learning recommendations from measured prediction, repair, and verifier outcomes.

  This module does not rewrite policy. It produces explicit proposed updates
  that can be reviewed, persisted, and applied by a policy owner.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_meta_learning_snapshot/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    calibrations = normalize_maps(RuntimeContracts.value(attrs, "outcome_calibrations"))
    repairs = normalize_maps(RuntimeContracts.value(attrs, "repair_effectiveness"))
    verifier_quality = normalize_maps(RuntimeContracts.value(attrs, "verifier_quality"))
    prior_lessons = normalize_maps(RuntimeContracts.value(attrs, "prior_lessons"))

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
        RuntimeContracts.stable_id("meta_learning", [
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
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp add_calibration_recommendations(acc, calibrations) do
    calibrations
    |> Enum.reject(&RuntimeContracts.truthy?(&1["matched"]))
    |> Enum.group_by(& &1["tool_name"])
    |> Enum.reduce(acc, fn {tool_name, items}, list ->
      if tool_name in [nil, ""] do
        list
      else
        [
          recommendation(
            "prediction_contract",
            tool_name,
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
    |> Enum.group_by(& &1["source_tool_name"])
    |> Enum.reduce(acc, fn {tool_name, items}, list ->
      if tool_name in [nil, ""] do
        list
      else
        [
          recommendation(
            "repair_policy",
            tool_name,
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
      accuracy = RuntimeContracts.number(quality["accuracy"], 0.5)

      if accuracy < 0.6 and quality["verifier_agent_id"] not in [nil, ""] do
        [
          recommendation(
            "verifier_assignment",
            quality["verifier_agent_id"],
            "deprioritize_until_recalibrated",
            "low_verifier_accuracy",
            RuntimeContracts.integer(quality["calibration_count"] || quality["sample_count"])
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
      mismatch_count = RuntimeContracts.integer(lesson["application_mismatch_count"])

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
      "recommendation_id" =>
        RuntimeContracts.stable_id("meta_rec", [target_type, target_id, action, reason_code]),
      "target_type" => target_type,
      "target_id" => target_id,
      "action" => action,
      "reason_code" => reason_code,
      "evidence_count" => evidence_count,
      "confidence" => confidence(evidence_count)
    }
    |> RuntimeContracts.reject_empty()
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
    mismatches = Enum.count(calibrations, &(not RuntimeContracts.truthy?(&1["matched"])))
    repair_required = Enum.count(repairs, &RuntimeContracts.truthy?(&1["repair_required"]))

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

  defp normalize_maps(value) when is_list(value) do
    value
    |> Enum.filter(&is_map/1)
    |> Enum.map(&RuntimeContracts.string_keys/1)
  end

  defp normalize_maps(_value), do: []
end
