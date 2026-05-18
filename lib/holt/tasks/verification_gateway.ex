defmodule Holt.Tasks.VerificationGateway do
  @moduledoc """
  Pure verification gate evaluator for local task runs.

  The gateway combines explicit check statuses, risk flags, and the evidence
  contract evaluation into the route that task and graph orchestration consume.
  """

  alias Holt.Clock
  alias Holt.Tasks.EvidenceContract

  @schema_version "holt_verification_gateway/v1"
  @route_schema_version "holt_verification_route/v1"
  @attention_statuses ~w(failed blocked needs_review)
  @check_statuses ~w(passed failed blocked needs_review)

  def evaluate(attrs \\ %{})

  def evaluate(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_gateway(input)
      {:error, reason} -> rejected(reason)
    end
  end

  def evaluate(_attrs), do: rejected("invalid_attrs")

  defp build_gateway(input) do
    evidence_evaluation =
      EvidenceContract.evaluate(%{
        "evidence_contract" => input.evidence_contract,
        "checks" => input.checks,
        "changed_files" => input.changed_files,
        "evidence" => input.evidence,
        "ui_walkthrough_status" => input.ui_walkthrough_status,
        "api_verification_status" => input.api_verification_status,
        "graphql_verification_status" => input.graphql_verification_status
      })

    checks_passed? = input.checks != [] and Enum.all?(input.checks, &(&1["status"] == "passed"))
    attention_required? = Enum.any?(input.checks, &(&1["status"] in @attention_statuses))
    evidence_satisfied? = Map.get(evidence_evaluation, "satisfied") == true

    can_finish? =
      checks_passed? and not attention_required? and input.risk_flags == [] and
        evidence_satisfied?

    reason =
      route_reason(can_finish?, attention_required?, input.risk_flags, evidence_satisfied?)

    route =
      %{
        "schema_version" => @route_schema_version,
        "can_finish" => can_finish?,
        "requires_human_review" => not can_finish?,
        "status" => if(can_finish?, do: "auto_finish", else: "needs_review"),
        "reason" => reason,
        "evidence_contract_satisfied" => evidence_satisfied?,
        "missing_requirements" => missing_requirements(evidence_evaluation)
      }
      |> compact()

    verifier = verifier_gate(route, evidence_evaluation, input.checks)

    %{
      "schema_version" => @schema_version,
      "status" => if(can_finish?, do: "submitted", else: gateway_status(input.checks, reason)),
      "required" => true,
      "satisfied" => can_finish?,
      "can_finish" => can_finish?,
      "reason" => reason,
      "route" => route,
      "evidence_contract" => input.evidence_contract,
      "evidence_evaluation" => evidence_evaluation,
      "verifier" => verifier,
      "risk_flags" => input.risk_flags,
      "failed_checks" => checks_with_status(input.checks, "failed"),
      "blocked_checks" => checks_with_status(input.checks, "blocked"),
      "unknown_checks" => checks_with_status(input.checks, "needs_review"),
      "evaluated_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason,
      "required" => true,
      "satisfied" => false,
      "can_finish" => false,
      "evaluated_at" => Clock.iso_now()
    }
  end

  def satisfied?(gateway) when is_map(gateway) do
    Map.get(gateway, "satisfied") == true
  end

  def satisfied?(_gateway), do: false

  def route(gateway) when is_map(gateway) do
    gateway
    |> Map.get("route")
    |> map_value()
  end

  def route(_gateway), do: %{}

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, checks} <- optional_checks(attrs),
         {:ok, risk_flags} <- optional_string_list(attrs, "risk_flags", "invalid_risk_flags"),
         {:ok, changed_files} <-
           optional_string_list(attrs, "changed_files", "invalid_changed_files"),
         {:ok, evidence} <- optional_string_list(attrs, "evidence", "invalid_evidence"),
         {:ok, ui_status} <-
           optional_text(attrs, "ui_walkthrough_status", "invalid_ui_walkthrough_status"),
         {:ok, api_status} <-
           optional_text(attrs, "api_verification_status", "invalid_api_verification_status"),
         {:ok, graphql_status} <-
           optional_text(
             attrs,
             "graphql_verification_status",
             "invalid_graphql_verification_status"
           ),
         {:ok, evidence_contract} <- optional_evidence_contract(attrs) do
      {:ok,
       %{
         checks: checks,
         risk_flags: risk_flags,
         changed_files: changed_files,
         evidence: evidence,
         ui_walkthrough_status: ui_status,
         api_verification_status: api_status,
         graphql_verification_status: graphql_status,
         evidence_contract: evidence_contract
       }}
    end
  end

  defp gateway_status(_checks, "all_checks_passed"), do: "submitted"
  defp gateway_status([], _reason), do: "required"
  defp gateway_status(_checks, _reason), do: "blocked"

  defp route_reason(true, _attention_required?, _risk_flags, _evidence_satisfied?) do
    "all_checks_passed"
  end

  defp route_reason(false, true, _risk_flags, _evidence_satisfied?) do
    "check_requires_attention"
  end

  defp route_reason(false, _attention_required?, [_flag | _rest], _evidence_satisfied?) do
    "risk_review_required"
  end

  defp route_reason(false, _attention_required?, _risk_flags, false) do
    "evidence_contract_not_satisfied"
  end

  defp route_reason(false, _attention_required?, _risk_flags, _evidence_satisfied?) do
    "verification_incomplete"
  end

  defp verifier_gate(route, evidence_evaluation, checks) do
    status =
      cond do
        route["can_finish"] == true ->
          "approved"

        checks == [] ->
          "pending"

        route["reason"] == "risk_review_required" ->
          "human_review_required"

        true ->
          "rejected"
      end

    %{
      "schema_version" => "holt_verifier_gate/v1",
      "strategy" => "structured_evidence_contract",
      "independent" => true,
      "status" => status,
      "reason" => verifier_reason(status, route),
      "missing_requirements" => missing_requirements(evidence_evaluation),
      "evaluated_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp verifier_reason("approved", _route), do: "structured_evidence_passed"
  defp verifier_reason("pending", _route), do: "verification_report_missing"
  defp verifier_reason("human_review_required", _route), do: "human_review_required"

  defp verifier_reason("rejected", route) do
    text(route, "reason", "verification_failed")
  end

  defp verifier_reason(_status, _route), do: "verification_incomplete"

  defp checks_with_status(checks, status) do
    Enum.filter(checks, &(&1["status"] == status))
  end

  defp optional_checks(attrs) do
    case Map.fetch(attrs, "checks") do
      {:ok, checks} when is_list(checks) -> normalize_checks(checks)
      {:ok, _checks} -> {:error, "invalid_checks"}
      :error -> {:ok, []}
    end
  end

  defp normalize_checks(checks) do
    checks
    |> Enum.reduce_while({:ok, []}, fn
      check, {:ok, acc} when is_map(check) ->
        case normalize_check(check) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          error -> {:halt, error}
        end

      _check, {:ok, _acc} ->
        {:halt, {:error, "invalid_checks"}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_check(check) do
    with {:ok, check_type} <- required_text(check, "check_type", "invalid_checks"),
         {:ok, status} <- required_enum(check, "status", @check_statuses, "invalid_checks"),
         {:ok, check} <- optional_text_field(check, "name", "invalid_checks"),
         {:ok, check} <- optional_text_field(check, "evidence", "invalid_checks"),
         {:ok, check} <- optional_text_field(check, "command", "invalid_checks") do
      {:ok,
       check
       |> Map.put("check_type", check_type)
       |> Map.put("status", status)
       |> compact()}
    end
  end

  defp missing_requirements(evidence_evaluation) do
    case Map.get(evidence_evaluation, "missing_requirements", []) do
      requirements when is_list(requirements) -> requirements
      _invalid -> []
    end
  end

  defp optional_string_list(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, values} when is_list(values) -> string_list(values, reason)
      {:ok, _values} -> {:error, reason}
      :error -> {:ok, []}
    end
  end

  defp string_list(values, reason) do
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
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp optional_evidence_contract(attrs) do
    case Map.fetch(attrs, "evidence_contract") do
      {:ok, value} when is_map(value) and value == %{} -> {:ok, EvidenceContract.build(%{})}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_evidence_contract"}
      :error -> {:ok, EvidenceContract.build(%{})}
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

  defp optional_text_field(check, key, reason) do
    case Map.fetch(check, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, reason}
          text -> {:ok, Map.put(check, key, text)}
        end

      {:ok, _value} ->
        {:error, reason}

      :error ->
        {:ok, check}
    end
  end

  defp required_text(attrs, key, reason) do
    case Map.fetch(attrs, key) do
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

  defp required_enum(attrs, key, allowed_values, reason) do
    case required_text(attrs, key, reason) do
      {:ok, value} ->
        if value in allowed_values, do: {:ok, value}, else: {:error, reason}

      error ->
        error
    end
  end

  defp map_value(value) when is_map(value) do
    if canonical_value?(value), do: value, else: %{}
  end

  defp map_value(_value), do: %{}

  defp text(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _value -> default
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

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
