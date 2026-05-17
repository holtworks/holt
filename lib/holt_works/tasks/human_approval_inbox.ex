defmodule HoltWorks.Tasks.HumanApprovalInbox do
  @moduledoc """
  Human approval request and resolution contracts for gated task actions.

  Requests are linked to an action runtime envelope so approval decisions can be
  audited and replayed without relying on prose.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.RuntimeContracts

  @schema_version "holtworks_human_approval_request/v1"
  @resolution_schema_version "holtworks_human_approval_resolution/v1"

  def build_request(attrs \\ %{})

  def build_request(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    envelope = envelope(attrs)
    action_contract = RuntimeContracts.normalize_map(envelope["action_contract"])
    policy_decision = RuntimeContracts.normalize_map(envelope["policy_decision"])
    capability = RuntimeContracts.normalize_map(action_contract["capability_registry_entry"])

    if approval_required?(envelope, policy_decision, capability, attrs) do
      prediction = RuntimeContracts.normalize_map(envelope["prediction"])
      rollback_contract = rollback_contract(action_contract, capability)

      %{
        "schema_version" => @schema_version,
        "approval_request_id" =>
          RuntimeContracts.stable_id("approval_request", [
            envelope["envelope_id"],
            action_contract["contract_id"],
            policy_decision["decision_id"]
          ]),
        "status" => "pending",
        "source_envelope_id" => envelope["envelope_id"],
        "tool_name" => action_contract["tool_name"] || envelope["tool_name"],
        "tool_call_id" => action_contract["tool_call_id"] || envelope["tool_call_id"],
        "action_type" => capability["action_type"],
        "effect_scope" => action_contract["effect_scope"] || capability["effect_scope"],
        "target_domain" => action_contract["target_domain"] || capability["target_domain"],
        "target_refs" => action_contract["target_refs"],
        "risk_level" => action_contract["risk_level"] || capability["risk_level"],
        "reason" => approval_reason(policy_decision, capability),
        "policy_decision" => policy_decision,
        "predicted_consequences" => prediction,
        "rollback_contract" => rollback_contract,
        "resume_options" => resume_options(envelope, rollback_contract),
        "required_decision" => "approve_or_reject",
        "created_at" => Clock.iso_now()
      }
      |> RuntimeContracts.reject_empty()
    end
  end

  def build_request(_attrs), do: nil

  def not_required(envelope) when is_map(envelope) do
    %{
      "schema_version" => @schema_version,
      "status" => "not_required",
      "source_envelope_id" => envelope["envelope_id"],
      "tool_name" => envelope["tool_name"],
      "reason" => "approval_not_required",
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def not_required(_envelope), do: not_required(%{})

  def resolve(request, attrs \\ %{})

  def resolve(request, attrs) when is_map(request) and is_map(attrs) do
    request = RuntimeContracts.string_keys(request)
    attrs = RuntimeContracts.string_keys(attrs)
    decision = normalize_decision(RuntimeContracts.value(attrs, "decision"))

    %{
      "schema_version" => @resolution_schema_version,
      "approval_request_id" => request["approval_request_id"],
      "source_envelope_id" => request["source_envelope_id"],
      "status" => resolution_status(decision),
      "decision" => decision,
      "decided_by" => RuntimeContracts.text(attrs, "decided_by", "user"),
      "decision_reason_code" => RuntimeContracts.text(attrs, "reason_code"),
      "can_resume" => decision == "approved",
      "resolved_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def resolve(_request, _attrs), do: {:error, :invalid_attrs}

  defp envelope(attrs) do
    RuntimeContracts.normalize_map(
      RuntimeContracts.value(attrs, "action_runtime_envelope") ||
        RuntimeContracts.value(attrs, "envelope")
    )
  end

  defp approval_required?(envelope, policy_decision, capability, attrs) do
    RuntimeContracts.truthy?(RuntimeContracts.value(attrs, "force_approval_request")) or
      envelope["execution_decision"] == "await_approval" or
      envelope["repair_directive"] == "await_human_approval" or
      policy_decision["action"] == "approval_required" or
      RuntimeContracts.value(capability["approval_policy"] || %{}, "mode") == "human_required"
  end

  defp approval_reason(policy_decision, capability) do
    policy_decision["reason"] ||
      RuntimeContracts.value(capability["approval_policy"] || %{}, "reason_code") ||
      "human_approval_required"
  end

  defp rollback_contract(action_contract, capability) do
    RuntimeContracts.normalize_map(
      action_contract["rollback_contract"] ||
        capability["rollback_contract"] ||
        action_contract["recovery"]
    )
  end

  defp resume_options(envelope, rollback_contract) do
    [
      %{"decision" => "approve", "effect" => "resume_action_execution"},
      %{"decision" => "reject", "effect" => "block_action_and_replan"},
      if(envelope["repair_directive"] == "await_human_approval",
        do: %{"decision" => "request_repair", "effect" => "enter_repair_phase"}
      ),
      if(RuntimeContracts.truthy?(rollback_contract["undoable"]),
        do: %{"decision" => "rollback", "effect" => rollback_contract["strategy"]}
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_decision(value) when value in ["approved", "approve", :approved, :approve],
    do: "approved"

  defp normalize_decision(value) when value in ["rejected", "reject", :rejected, :reject],
    do: "rejected"

  defp normalize_decision(value) when value in ["denied", "deny", :denied, :deny],
    do: "rejected"

  defp normalize_decision(value) when value in ["expired", :expired], do: "expired"
  defp normalize_decision(_value), do: "unresolved"

  defp resolution_status("approved"), do: "approved"
  defp resolution_status("rejected"), do: "rejected"
  defp resolution_status("expired"), do: "expired"
  defp resolution_status(_decision), do: "pending"
end
