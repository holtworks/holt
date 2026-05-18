defmodule Holt.Tasks.HumanApprovalInbox do
  @moduledoc """
  Human approval request and resolution contracts for gated task actions.

  Requests are linked to an action runtime envelope so approval decisions can be
  audited and replayed without relying on prose.
  """

  alias Holt.Clock

  @schema_version "holt_human_approval_request/v1"
  @resolution_schema_version "holt_human_approval_resolution/v1"

  def build_request(attrs \\ %{})

  def build_request(attrs) when is_map(attrs) do
    case request_input(attrs) do
      {:ok, input} -> build_canonical_request(input)
      {:error, reason} -> rejected_request(attrs, reason)
    end
  end

  def build_request(_attrs), do: rejected_request(%{}, "invalid_attrs")

  def not_required(envelope) when is_map(envelope) do
    %{
      "schema_version" => @schema_version,
      "status" => "not_required",
      "source_envelope_id" => envelope["envelope_id"],
      "action" => envelope["action"],
      "reason" => "approval_not_required",
      "created_at" => Clock.iso_now()
    }
    |> compact()
  end

  def not_required(_envelope), do: not_required(%{})

  def resolve(request, attrs \\ %{})

  def resolve(request, attrs) when is_map(request) and is_map(attrs) do
    case resolution_input(request, attrs) do
      {:ok, input} -> build_resolution(input)
      {:error, reason} -> rejected_resolution(request, reason)
    end
  end

  def resolve(_request, _attrs), do: {:error, :invalid_attrs}

  defp request_input(attrs) do
    with :ok <- canonical_attrs(attrs),
         :ok <- unsupported_arguments(attrs),
         {:ok, envelope} <- runtime_envelope(attrs),
         {:ok, force} <-
           optional_boolean(attrs, "force_approval_request", "invalid_force_approval_request") do
      {:ok, %{envelope: envelope, force_approval_request: force}}
    end
  end

  defp build_canonical_request(input) do
    envelope = input.envelope
    action_contract = envelope["action_contract"]
    policy_decision = envelope["policy_decision"]
    capability = optional_map_value(action_contract, "capability_registry_entry")

    case approval_required?(envelope, policy_decision, capability, input.force_approval_request) do
      true ->
        prediction = optional_map_value(envelope, "prediction")
        rollback_contract = optional_map_value(action_contract, "recovery")

        %{
          "schema_version" => @schema_version,
          "approval_request_id" =>
            stable_id("approval_request", [
              envelope["envelope_id"],
              action_contract["contract_id"],
              policy_decision["decision_id"]
            ]),
          "status" => "pending",
          "source_envelope_id" => envelope["envelope_id"],
          "action" => action_contract["action"],
          "action_call_id" => action_contract["action_call_id"],
          "action_type" => capability["action_type"],
          "effect_scope" => action_contract["effect_scope"],
          "target_domain" => action_contract["target_domain"],
          "target_refs" => action_contract["target_refs"],
          "risk_level" => action_contract["risk_level"],
          "reason" => approval_reason(policy_decision, capability),
          "policy_decision" => policy_decision,
          "predicted_consequences" => prediction,
          "rollback_contract" => rollback_contract,
          "resume_options" => resume_options(envelope, rollback_contract),
          "required_decision" => "approve_or_reject",
          "created_at" => Clock.iso_now()
        }
        |> compact()

      false ->
        nil
    end
  end

  defp rejected_request(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "approval_request_id" =>
        output_text(
          attrs,
          "approval_request_id",
          stable_id("approval_request", [reason, attrs])
        ),
      "status" => "rejected",
      "reason" => reason,
      "created_at" => Clock.iso_now()
    }
  end

  defp resolution_input(request, attrs) do
    with :ok <- canonical_attrs(request),
         :ok <- canonical_attrs(attrs),
         :ok <- validate_request(request),
         {:ok, decision} <- approval_decision(attrs),
         {:ok, decided_by} <- optional_text(attrs, "decided_by", "invalid_decided_by"),
         {:ok, reason_code} <- optional_text(attrs, "reason_code", "invalid_reason_code") do
      {:ok,
       %{
         request: request,
         decision: decision,
         decided_by: text_default(decided_by, "user"),
         reason_code: reason_code
       }}
    end
  end

  defp build_resolution(input) do
    request = input.request
    decision = input.decision

    %{
      "schema_version" => @resolution_schema_version,
      "approval_request_id" => request["approval_request_id"],
      "source_envelope_id" => request["source_envelope_id"],
      "status" => resolution_status(decision),
      "decision" => decision,
      "decided_by" => input.decided_by,
      "decision_reason_code" => input.reason_code,
      "can_resume" => decision == "approved",
      "resolved_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_resolution(request, reason) do
    %{
      "schema_version" => @resolution_schema_version,
      "approval_request_id" => output_text(request, "approval_request_id", nil),
      "source_envelope_id" => output_text(request, "source_envelope_id", nil),
      "status" => "rejected",
      "decision" => "invalid",
      "reason" => reason,
      "can_resume" => false,
      "resolved_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp runtime_envelope(attrs) do
    case Map.fetch(attrs, "action_runtime_envelope") do
      {:ok, envelope} when is_map(envelope) ->
        with :ok <- validate_runtime_envelope(envelope) do
          {:ok, envelope}
        end

      {:ok, _envelope} ->
        {:error, "invalid_action_runtime_envelope"}

      :error ->
        {:error, "invalid_action_runtime_envelope"}
    end
  end

  defp validate_runtime_envelope(envelope) do
    with {:ok, _envelope_id} <-
           required_text(envelope, "envelope_id", "invalid_action_runtime_envelope"),
         :ok <-
           optional_text_field(envelope, "execution_decision", "invalid_action_runtime_envelope"),
         :ok <-
           optional_text_field(envelope, "repair_directive", "invalid_action_runtime_envelope"),
         :ok <- required_map(envelope, "action_contract", "invalid_action_runtime_envelope"),
         :ok <- required_map(envelope, "policy_decision", "invalid_action_runtime_envelope"),
         :ok <- optional_map_field(envelope, "prediction", "invalid_action_runtime_envelope"),
         :ok <- validate_action_contract(envelope["action_contract"]),
         :ok <- validate_policy_decision(envelope["policy_decision"]) do
      :ok
    end
  end

  defp validate_action_contract(contract) do
    with {:ok, _contract_id} <-
           required_text(contract, "contract_id", "invalid_action_runtime_envelope"),
         {:ok, _action} <- required_text(contract, "action", "invalid_action_runtime_envelope"),
         {:ok, _effect_scope} <-
           required_text(contract, "effect_scope", "invalid_action_runtime_envelope"),
         :ok <- optional_map_field(contract, "target_refs", "invalid_action_runtime_envelope"),
         :ok <- optional_map_field(contract, "recovery", "invalid_action_runtime_envelope"),
         :ok <-
           optional_map_field(
             contract,
             "capability_registry_entry",
             "invalid_action_runtime_envelope"
           ) do
      :ok
    end
  end

  defp validate_policy_decision(policy) do
    with {:ok, _decision_id} <-
           required_text(policy, "decision_id", "invalid_action_runtime_envelope"),
         {:ok, action} <- required_text(policy, "action", "invalid_action_runtime_envelope"),
         :ok <- policy_action(action),
         :ok <- optional_text_field(policy, "reason", "invalid_action_runtime_envelope") do
      :ok
    end
  end

  defp validate_request(request) do
    with {:ok, _request_id} <- required_text(request, "approval_request_id", "invalid_request"),
         :ok <- optional_text_field(request, "source_envelope_id", "invalid_request") do
      :ok
    end
  end

  defp approval_required?(envelope, policy_decision, capability, force) do
    approval_policy = optional_map_value(capability, "approval_policy")

    cond do
      force == true -> true
      envelope["execution_decision"] == "await_approval" -> true
      envelope["repair_directive"] == "await_human_approval" -> true
      policy_decision["action"] == "approval_required" -> true
      approval_policy["mode"] == "human_required" -> true
      true -> false
    end
  end

  defp approval_reason(policy_decision, capability) do
    approval_policy = optional_map_value(capability, "approval_policy")

    case text_field(policy_decision, "reason") do
      nil -> text_default(text_field(approval_policy, "reason_code"), "human_approval_required")
      reason -> reason
    end
  end

  defp resume_options(envelope, rollback_contract) do
    [
      %{"decision" => "approve", "effect" => "resume_action_execution"},
      %{"decision" => "reject", "effect" => "block_action_and_replan"},
      repair_option(envelope),
      rollback_option(rollback_contract)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp repair_option(%{"repair_directive" => "await_human_approval"}) do
    %{"decision" => "request_repair", "effect" => "enter_repair_phase"}
  end

  defp repair_option(_envelope), do: nil

  defp rollback_option(%{"undoable" => true, "strategy" => strategy}) when is_binary(strategy) do
    %{"decision" => "rollback", "effect" => strategy}
  end

  defp rollback_option(_rollback_contract), do: nil

  defp approval_decision(attrs) do
    case Map.fetch(attrs, "decision") do
      {:ok, value} when value in ["approved", "rejected", "expired"] -> {:ok, value}
      {:ok, _value} -> {:error, "invalid_decision"}
      :error -> {:ok, "unresolved"}
    end
  end

  defp resolution_status("approved"), do: "approved"
  defp resolution_status("rejected"), do: "rejected"
  defp resolution_status("expired"), do: "expired"
  defp resolution_status(_decision), do: "pending"

  defp policy_action("approved"), do: :ok
  defp policy_action("rejected"), do: :ok
  defp policy_action("approval_required"), do: :ok
  defp policy_action(_action), do: {:error, "invalid_action_runtime_envelope"}

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
    case Map.has_key?(attrs, "envelope") do
      true -> {:error, "unsupported_argument:envelope"}
      false -> :ok
    end
  end

  defp required_map(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> {:error, reason}
    end
  end

  defp optional_map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> value
      _missing -> %{}
    end
  end

  defp optional_map_field(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, _value} -> {:error, reason}
      :error -> :ok
    end
  end

  defp optional_boolean(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, false}
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
    case optional_text(map, key, reason) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_text(map, key, reason) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        {:ok, trim_empty(value)}

      {:ok, _value} ->
        {:error, reason}
    end
  end

  defp text_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> trim_empty(value)
      _missing -> nil
    end
  end

  defp text_field(_map, _key), do: nil

  defp output_text(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> text_default(trim_empty(value), default)
      _missing -> default
    end
  end

  defp output_text(_map, _key, default), do: default

  defp text_default(nil, default), do: default
  defp text_default(value, _default), do: value

  defp trim_empty(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

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
