defmodule Holt.Tasks.VerificationContract do
  @moduledoc """
  Structured acceptance and evidence contract for task-agent verification.
  """

  alias Holt.Tasks.RuntimeContracts

  @schema_version "holtworks_verification_contract/v1"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    required? = verification_required?(attrs)

    %{
      "schema_version" => @schema_version,
      "required" => required?,
      "gate_tool" => "route_verification_review",
      "review_strategy" => review_strategy(attrs),
      "artifact_kinds" => artifact_kinds(required?),
      "evidence_required" => required?,
      "evidence_contract" => RuntimeContracts.normalize_map(attrs["evidence_contract"]),
      "max_attempts" => max_attempts(attrs),
      "pass_policy" => pass_policy(attrs),
      "source" => RuntimeContracts.text(attrs, "source", "agent_run_policy")
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  defp verification_required?(attrs) do
    case RuntimeContracts.value(attrs, "verification_required") do
      false -> false
      "false" -> false
      0 -> false
      nil -> true
      _value -> true
    end
  end

  defp review_strategy(attrs) do
    RuntimeContracts.text(
      attrs,
      "review_strategy",
      RuntimeContracts.text(attrs, "review_gate_mode", "task_definition_of_done")
    )
  end

  defp artifact_kinds(true), do: ["verification_report"]
  defp artifact_kinds(false), do: []

  defp max_attempts(attrs) do
    attrs
    |> RuntimeContracts.value("max_attempts")
    |> RuntimeContracts.integer()
    |> case do
      int when int > 0 -> min(int, 5)
      _int -> 1
    end
  end

  defp pass_policy(attrs) do
    if RuntimeContracts.truthy?(RuntimeContracts.value(attrs, "require_passing_grade")) do
      "passing_grade_required"
    else
      "evidence_required"
    end
  end
end
