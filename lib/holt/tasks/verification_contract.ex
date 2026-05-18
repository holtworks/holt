defmodule Holt.Tasks.VerificationContract do
  @moduledoc """
  Structured acceptance and evidence contract for task-agent verification.
  """

  @schema_version "holt_verification_contract/v1"
  @unsupported_keys ~w(review_gate_mode)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_contract(reason)
    end
  end

  def build(_attrs), do: rejected_contract("invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, required?} <-
           optional_boolean(attrs, "verification_required", true, "invalid_verification_required"),
         {:ok, review_strategy} <-
           optional_text(
             attrs,
             "review_strategy",
             "task_definition_of_done",
             "invalid_review_strategy"
           ),
         {:ok, evidence_contract} <-
           optional_map(attrs, "evidence_contract", "invalid_evidence_contract"),
         {:ok, max_attempts} <- optional_attempts(attrs),
         {:ok, passing_grade?} <-
           optional_boolean(
             attrs,
             "require_passing_grade",
             false,
             "invalid_require_passing_grade"
           ),
         {:ok, source} <- optional_text(attrs, "source", "agent_run_policy", "invalid_source") do
      {:ok,
       %{
         required?: required?,
         review_strategy: review_strategy,
         evidence_contract: evidence_contract,
         max_attempts: max_attempts,
         passing_grade?: passing_grade?,
         source: source
       }}
    end
  end

  defp build_canonical(input) do
    %{
      "schema_version" => @schema_version,
      "required" => input.required?,
      "gate_action" => "route_verification_review",
      "review_strategy" => input.review_strategy,
      "artifact_kinds" => artifact_kinds(input.required?),
      "evidence_required" => input.required?,
      "evidence_contract" => input.evidence_contract,
      "max_attempts" => input.max_attempts,
      "pass_policy" => pass_policy(input.passing_grade?),
      "source" => input.source
    }
    |> compact()
  end

  defp rejected_contract(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  defp artifact_kinds(true), do: ["verification_report"]
  defp artifact_kinds(false), do: []

  defp pass_policy(true), do: "passing_grade_required"
  defp pass_policy(false), do: "evidence_required"

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
    attrs
    |> Map.keys()
    |> Enum.find(&(&1 in @unsupported_keys))
    |> unsupported_key_error()
  end

  defp unsupported_key_error(nil), do: :ok
  defp unsupported_key_error(key), do: {:error, "unsupported_argument:" <> key}

  defp optional_boolean(attrs, key, default, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, default}
    end
  end

  defp optional_attempts(attrs) do
    case Map.fetch(attrs, "max_attempts") do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, min(value, 5)}
      {:ok, _value} -> {:error, "invalid_max_attempts"}
      :error -> {:ok, 1}
    end
  end

  defp optional_map(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp optional_text(attrs, key, default, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, default}
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(value), do: value in [nil, "", [], %{}]
end
