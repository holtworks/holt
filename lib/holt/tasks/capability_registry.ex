defmodule Holt.Tasks.CapabilityRegistry do
  @moduledoc """
  Server-owned capability descriptions for local task actions.

  The registry is metadata only. It describes action effect scope, risk, state
  read/write expectations, verification posture, and approval policy before the
  execution layer considers running anything.
  """

  alias Holt.Clock

  alias Holt.Tasks.{
    ActionContract,
    ActionSession
  }

  @schema_version "holt_capability_registry_entry/v1"

  def lookup(action_name, attrs \\ %{})

  def lookup(action_name, attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, action_name} <- registry_action(action_name),
         {:ok, contract} <- action_contract(action_name, attrs),
         {:ok, effect_scope} <- contract_text(contract, "effect_scope", "unknown"),
         action_type = action_type(action_name, effect_scope),
         {:ok, target_domain} <-
           contract_text(contract, "target_domain", target_domain(effect_scope)),
         {:ok, risk_level} <-
           contract_text(contract, "risk_level", risk_level(effect_scope, target_domain)),
         {:ok, target_refs} <- map_field(contract, "target_refs") do
      %{
        "schema_version" => @schema_version,
        "capability_id" =>
          stable_id("capability", [
            action_name,
            action_type,
            effect_scope,
            target_domain
          ]),
        "registered" => action_name in registered_actions(),
        "action" => action_name,
        "action_type" => action_type,
        "effect_scope" => effect_scope,
        "target_domain" => target_domain,
        "risk_level" => risk_level,
        "risk_flags" => risk_flags(action_type, effect_scope, target_domain, risk_level),
        "input_contract" => input_contract(action_name, action_type, target_domain),
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
      |> reject_empty()
    else
      {:error, reason} -> rejected_entry(reason)
    end
  end

  def lookup(_action_name, _attrs), do: rejected_entry("invalid_attrs")

  defp rejected_entry(reason) do
    %{
      "schema_version" => @schema_version,
      "status" => "rejected",
      "reason" => reason
    }
  end

  def registered_actions do
    (ActionSession.direct_action_names() ++ ActionSession.meta_action_names())
    |> Enum.uniq()
  end

  def all do
    registered_actions()
    |> Enum.map(&lookup/1)
  end

  defp action_contract(action_name, attrs) do
    case Map.fetch(attrs, "action_contract") do
      {:ok, contract} when is_map(contract) ->
        canonical_nested_map("action_contract", contract)

      {:ok, _value} ->
        {:error, "invalid_field:action_contract"}

      :error ->
        case ActionContract.build(Map.put(attrs, "action", action_name)) do
          contract when is_map(contract) -> {:ok, contract}
          {:error, _reason} -> {:error, "invalid_field:action_contract"}
        end
    end
  end

  defp registry_action(nil), do: {:ok, "unknown"}

  defp registry_action(action_name) when is_binary(action_name) do
    case String.trim(action_name) do
      "" -> {:ok, "unknown"}
      action -> {:ok, action}
    end
  end

  defp registry_action(_action_name), do: {:error, "invalid_action"}

  defp contract_text(contract, key, default) do
    case Map.fetch(contract, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          text -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, "invalid_field:action_contract"}

      :error ->
        {:ok, default}
    end
  end

  defp action_type(action_name, _scope)
       when action_name in [
              "route_verification_review",
              "get_evidence_contract",
              "plan_verifier_route",
              "verification_contract",
              "verifier_assignment",
              "verifier_calibration"
            ],
       do: "verify"

  defp action_type(action_name, _scope)
       when action_name in [
              "start_agent_work",
              "continue_agent_work",
              "watchdog_agent_runs",
              "verifier_dispatch"
            ],
       do: "delegate"

  defp action_type(_action_name, "read_only"), do: "read"
  defp action_type(_action_name, "session_ephemeral"), do: "session"
  defp action_type(_action_name, "routed"), do: "route"
  defp action_type(_action_name, "external_side_effect"), do: "external_side_effect"
  defp action_type(_action_name, "unknown"), do: "unknown"
  defp action_type(_action_name, _scope), do: "mutate"

  defp target_domain("read_only"), do: "task"
  defp target_domain("session_ephemeral"), do: "session_state"
  defp target_domain("task_durable"), do: "task"
  defp target_domain("agent_orchestration"), do: "agent_work"
  defp target_domain("workspace_durable"), do: "workspace"
  defp target_domain("external_side_effect"), do: "external_network"
  defp target_domain("routed"), do: "action_router"
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

  defp input_contract(action_name, action_type, target_domain) do
    %{
      "schema_type" => "json_object",
      "action" => action_name,
      "action_type" => action_type,
      "target_domain" => target_domain,
      "required_context" => required_context(action_type),
      "required_arguments" => required_arguments(action_type, target_domain)
    }
    |> reject_empty()
  end

  defp required_context("read"), do: ["action_session"]
  defp required_context("session"), do: ["action_session"]
  defp required_context("route"), do: ["action_session", "action_contract"]
  defp required_context("unknown"), do: ["explicit_capability_registration"]
  defp required_context(_action_type), do: ["task_id", "agent_id", "action_session"]

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
  defp expected_outputs(_action_type, _scope), do: ["action_result", "state_delta"]

  defp state_read_model(effect_scope, target_domain, target_refs) do
    %{
      "required" => effect_scope != "routed",
      "sources" => read_sources(effect_scope, target_domain),
      "target_refs" => target_refs
    }
    |> reject_empty()
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
    |> reject_empty()
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
      "gate_action" => "route_verification_review",
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

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> canonical_nested_map(key, value)
      {:ok, _value} -> {:error, "invalid_field:#{key}"}
      :error -> {:ok, %{}}
    end
  end

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp canonical_nested_map(key, map) do
    if canonical_value?(map) do
      {:ok, map}
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
