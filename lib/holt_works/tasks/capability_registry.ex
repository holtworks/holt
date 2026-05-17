defmodule HoltWorks.Tasks.CapabilityRegistry do
  @moduledoc """
  Server-owned capability descriptions for local task tools.

  The registry is metadata only. It describes tool effect scope, risk, state
  read/write expectations, verification posture, and approval policy before the
  execution layer considers running anything.
  """

  alias HoltWorks.Clock

  alias HoltWorks.Tasks.{
    ActionContract,
    RuntimeContracts,
    TaskToolSession
  }

  @schema_version "holtworks_capability_registry_entry/v1"

  def lookup(tool_name, attrs \\ %{})

  def lookup(tool_name, attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)

    tool_name =
      normalize_tool_name(tool_name) || RuntimeContracts.text(attrs, "tool_name", "unknown")

    contract = action_contract(tool_name, attrs)
    effect_scope = contract["effect_scope"] || "unknown"
    action_type = action_type(tool_name, effect_scope)
    target_domain = contract["target_domain"] || target_domain(effect_scope)
    risk_level = contract["risk_level"] || risk_level(effect_scope, target_domain)
    target_refs = RuntimeContracts.normalize_map(contract["target_refs"])

    %{
      "schema_version" => @schema_version,
      "capability_id" =>
        RuntimeContracts.stable_id("capability", [
          tool_name,
          action_type,
          effect_scope,
          target_domain
        ]),
      "registered" => tool_name in registered_tools(),
      "tool_name" => tool_name,
      "action_type" => action_type,
      "effect_scope" => effect_scope,
      "target_domain" => target_domain,
      "risk_level" => risk_level,
      "risk_flags" => risk_flags(action_type, effect_scope, target_domain, risk_level),
      "input_contract" => input_contract(tool_name, action_type, target_domain),
      "expected_outputs" => expected_outputs(action_type, effect_scope),
      "state_read_model" => state_read_model(effect_scope, target_domain, target_refs),
      "state_write_model" =>
        state_write_model(action_type, effect_scope, target_domain, target_refs),
      "prediction_contract" => prediction_contract(action_type, effect_scope),
      "verification_contract" => verification_contract(action_type, effect_scope, risk_level),
      "rollback_contract" => rollback_contract(effect_scope, target_refs),
      "approval_policy" => approval_policy(effect_scope, target_domain, risk_level),
      "allowed_roles" => allowed_roles(action_type, effect_scope),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def lookup(tool_name, _attrs), do: lookup(tool_name, %{})

  def registered_tools do
    (TaskToolSession.direct_tool_names() ++ TaskToolSession.meta_tool_names())
    |> Enum.uniq()
  end

  def all do
    registered_tools()
    |> Enum.map(&lookup/1)
  end

  defp action_contract(tool_name, attrs) do
    case RuntimeContracts.value(attrs, "action_contract") do
      contract when is_map(contract) ->
        RuntimeContracts.string_keys(contract)

      _missing ->
        ActionContract.build(Map.put(attrs, "tool_name", tool_name))
    end
  end

  defp action_type(tool_name, _scope)
       when tool_name in [
              "route_verification_review",
              "get_evidence_contract",
              "plan_verifier_route",
              "verification_contract",
              "verifier_assignment",
              "verifier_calibration"
            ],
       do: "verify"

  defp action_type(tool_name, _scope)
       when tool_name in [
              "start_agent_work",
              "continue_agent_work",
              "watchdog_agent_runs",
              "verifier_dispatch"
            ],
       do: "delegate"

  defp action_type(_tool_name, "read_only"), do: "read"
  defp action_type(_tool_name, "session_ephemeral"), do: "session"
  defp action_type(_tool_name, "routed"), do: "route"
  defp action_type(_tool_name, "external_side_effect"), do: "external_side_effect"
  defp action_type(_tool_name, "unknown"), do: "unknown"
  defp action_type(_tool_name, _scope), do: "mutate"

  defp target_domain("read_only"), do: "task"
  defp target_domain("session_ephemeral"), do: "session_state"
  defp target_domain("task_durable"), do: "task"
  defp target_domain("agent_orchestration"), do: "agent_work"
  defp target_domain("workspace_durable"), do: "workspace"
  defp target_domain("external_side_effect"), do: "external_network"
  defp target_domain("routed"), do: "task_tool_router"
  defp target_domain(_scope), do: "unknown"

  defp risk_level("read_only", _domain), do: "low"
  defp risk_level("session_ephemeral", _domain), do: "low"
  defp risk_level("routed", _domain), do: "medium"
  defp risk_level("task_durable", _domain), do: "medium"
  defp risk_level("agent_orchestration", _domain), do: "medium"
  defp risk_level("workspace_durable", _domain), do: "high"
  defp risk_level("external_side_effect", _domain), do: "high"
  defp risk_level(_scope, _domain), do: "unknown"

  defp risk_flags("unknown", _scope, _domain, _risk), do: ["unknown_capability"]
  defp risk_flags(_action_type, "external_side_effect", _domain, _risk), do: ["external_state"]
  defp risk_flags(_action_type, "workspace_durable", _domain, _risk), do: ["workspace_mutation"]
  defp risk_flags("delegate", _scope, _domain, _risk), do: ["child_agent_orchestration"]
  defp risk_flags(_action_type, _scope, _domain, "high"), do: ["human_approval_expected"]
  defp risk_flags(_action_type, _scope, _domain, _risk), do: []

  defp input_contract(tool_name, action_type, target_domain) do
    %{
      "schema_type" => "json_object",
      "tool_name" => tool_name,
      "action_type" => action_type,
      "target_domain" => target_domain,
      "required_context" => required_context(action_type),
      "required_arguments" => required_arguments(action_type, target_domain)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp required_context("read"), do: ["task_tool_session"]
  defp required_context("session"), do: ["task_tool_session"]
  defp required_context("route"), do: ["task_tool_session", "action_contract"]
  defp required_context("unknown"), do: ["explicit_capability_registration"]
  defp required_context(_action_type), do: ["task_id", "agent_id", "task_tool_session"]

  defp required_arguments("external_side_effect", _domain), do: ["external_target_ref"]
  defp required_arguments("delegate", _domain), do: ["message"]
  defp required_arguments("verify", _domain), do: ["structured_verdict"]
  defp required_arguments(_action_type, _domain), do: []

  defp expected_outputs("read", _scope), do: ["state_observation"]
  defp expected_outputs("session", _scope), do: ["session_state"]
  defp expected_outputs("route", _scope), do: ["nested_action_route"]
  defp expected_outputs("verify", _scope), do: ["structured_verdict", "evidence_evaluation"]
  defp expected_outputs("delegate", _scope), do: ["agent_work_contract"]

  defp expected_outputs("external_side_effect", _scope),
    do: ["external_receipt", "state_observation"]

  defp expected_outputs("unknown", _scope), do: ["capability_registration_required"]
  defp expected_outputs(_action_type, _scope), do: ["tool_result", "state_delta"]

  defp state_read_model(effect_scope, target_domain, target_refs) do
    %{
      "required" => effect_scope != "routed",
      "sources" => read_sources(effect_scope, target_domain),
      "target_refs" => target_refs
    }
    |> RuntimeContracts.reject_empty()
  end

  defp read_sources("read_only", domain), do: [domain]
  defp read_sources("session_ephemeral", domain), do: [domain]
  defp read_sources("task_durable", domain), do: [domain]
  defp read_sources("agent_orchestration", _domain), do: ["agent_run_state", "task"]
  defp read_sources("workspace_durable", _domain), do: ["workspace_state"]
  defp read_sources("external_side_effect", _domain), do: ["external_target_state"]
  defp read_sources("routed", _domain), do: ["nested_action_contract"]
  defp read_sources(_scope, domain), do: [domain]

  defp state_write_model("read", _scope, _domain, _target_refs), do: %{"writes" => []}
  defp state_write_model("route", _scope, _domain, _target_refs), do: %{"writes" => []}
  defp state_write_model("unknown", _scope, _domain, _target_refs), do: %{"writes" => ["unknown"]}

  defp state_write_model(action_type, effect_scope, target_domain, target_refs) do
    %{
      "writes" => write_targets(action_type, effect_scope, target_domain),
      "target_refs" => target_refs,
      "requires_reconciliation" => true
    }
    |> RuntimeContracts.reject_empty()
  end

  defp write_targets("delegate", _scope, _domain), do: ["agent_work"]
  defp write_targets("verify", _scope, _domain), do: ["verification_record"]
  defp write_targets("external_side_effect", _scope, _domain), do: ["external_system"]
  defp write_targets(_action_type, "task_durable", domain), do: [domain]
  defp write_targets(_action_type, "agent_orchestration", _domain), do: ["agent_work"]
  defp write_targets(_action_type, "workspace_durable", _domain), do: ["workspace"]
  defp write_targets(_action_type, _scope, domain), do: [domain]

  defp prediction_contract(action_type, effect_scope) do
    %{
      "required" => action_type not in ["read", "route", "session"],
      "must_predict_result_status" => true,
      "must_predict_state_delta" =>
        effect_scope not in ["read_only", "session_ephemeral", "routed"],
      "must_predict_repair_path" => action_type not in ["read", "route", "session"]
    }
  end

  defp verification_contract("read", _scope, _risk), do: %{"required" => false}
  defp verification_contract("session", _scope, _risk), do: %{"required" => false}
  defp verification_contract("route", _scope, _risk), do: %{"required" => false}

  defp verification_contract(_action_type, _scope, risk) do
    %{
      "required" => true,
      "gate_tool" => "route_verification_review",
      "review_strategy" =>
        if(risk == "high", do: "human_or_independent_agent", else: "structured_gate"),
      "artifact_kinds" => ["verification_report"]
    }
  end

  defp rollback_contract("read_only", _target_refs) do
    %{"available" => true, "strategy" => "none_required", "undoable" => true}
  end

  defp rollback_contract("session_ephemeral", _target_refs) do
    %{"available" => true, "strategy" => "overwrite_session_state", "undoable" => true}
  end

  defp rollback_contract("task_durable", target_refs) do
    %{
      "available" => true,
      "strategy" => "compensating_task_update",
      "undoable" => true,
      "target_refs" => target_refs
    }
  end

  defp rollback_contract("agent_orchestration", target_refs) do
    %{
      "available" => true,
      "strategy" => "cancel_or_mark_blocked",
      "undoable" => true,
      "target_refs" => target_refs
    }
  end

  defp rollback_contract("workspace_durable", target_refs) do
    %{
      "available" => true,
      "strategy" => "manual_or_file_revert",
      "undoable" => false,
      "target_refs" => target_refs
    }
  end

  defp rollback_contract(_scope, target_refs) do
    %{
      "available" => false,
      "strategy" => "manual_review_required",
      "undoable" => false,
      "target_refs" => target_refs
    }
  end

  defp approval_policy(_scope, _domain, risk) when risk in ["high", "critical"] do
    %{"mode" => "human_required", "reason_code" => "high_risk_capability"}
  end

  defp approval_policy("workspace_durable", _domain, _risk) do
    %{"mode" => "human_required", "reason_code" => "workspace_mutation"}
  end

  defp approval_policy("external_side_effect", _domain, _risk) do
    %{"mode" => "human_required", "reason_code" => "external_side_effect"}
  end

  defp approval_policy(_scope, _domain, _risk), do: %{"mode" => "policy_checked"}

  defp allowed_roles("verify", _scope), do: ["verifier", "critic", "worker"]
  defp allowed_roles("delegate", _scope), do: ["planner", "operator", "worker"]

  defp allowed_roles("read", _scope),
    do: ["worker", "researcher", "verifier", "critic", "planner"]

  defp allowed_roles(_action_type, "workspace_durable"), do: ["operator", "worker"]
  defp allowed_roles(_action_type, _scope), do: ["worker", "operator", "planner"]

  defp normalize_tool_name(nil), do: nil

  defp normalize_tool_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      tool_name -> tool_name
    end
  end
end
