defmodule Holt.Tasks.ChildAgentContract do
  @moduledoc """
  Structured contract for parent-bounded child-agent work.

  Child agents are useful only when authority, objective, expected outputs, and
  verification boundaries are explicit before the child starts.
  """

  alias Holt.Clock
  alias Holt.Tasks.{ActionContract, RuntimeContracts}

  @schema_version "holtworks_child_agent_contract/v1"
  @orchestration_tools ~w(delegate_to_agent invoke_agent start_agent_work continue_agent_work)
  @work_roles ~w(worker verifier researcher critic planner operator executor fixer)
  @verifier_skills ~w(task.validate api.test graphql.test browser.verify route_verification_review)
  @researcher_skills ~w(research.web research)
  @critic_skills ~w(task.critique design.review code.review)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    tool_name = RuntimeContracts.text(attrs, "tool_name", "delegate_to_agent")

    arguments =
      attrs["arguments"]
      |> RuntimeContracts.normalize_map()
      |> maybe_put_argument("work_role", attrs["work_role"] || attrs["role"])
      |> maybe_put_argument("target_agent_id", attrs["target_agent_id"] || attrs["agent_id"])
      |> maybe_put_argument("target_skill", attrs["target_skill"] || attrs["skill"])

    context = RuntimeContracts.normalize_map(attrs["context"])
    plan_contract = RuntimeContracts.normalize_map(attrs["plan_contract"])
    action_contract = RuntimeContracts.normalize_map(attrs["action_contract"])
    child_ref = child_ref(arguments, attrs)

    target_skill =
      RuntimeContracts.text(arguments, "target_skill", RuntimeContracts.text(arguments, "skill"))

    role = work_role(arguments, tool_name)
    allowed_tools = RuntimeContracts.normalize_string_list(arguments["allowed_tools"])
    allowed_effect_scopes = allowed_effect_scopes(allowed_tools, plan_contract)
    validation_contract = RuntimeContracts.text(arguments, "validation_contract")
    evidence_contract = evidence_contract(attrs, plan_contract)

    %{
      "schema_version" => @schema_version,
      "child_contract_id" =>
        RuntimeContracts.stable_id("child_contract", [
          plan_contract["plan_id"],
          action_contract["contract_id"],
          attrs["tool_call_id"],
          tool_name,
          child_ref,
          target_skill,
          role,
          allowed_tools,
          validation_contract
        ]),
      "status" => "active",
      "tool_name" => tool_name,
      "tool_call_id" => attrs["tool_call_id"],
      "parent" => parent_boundary(context, plan_contract, action_contract, attrs),
      "child" => child_boundary(child_ref, target_skill, role, tool_name),
      "job_contract" => job_contract(arguments, target_skill, allowed_tools, validation_contract),
      "authority_boundary" =>
        authority_boundary(context, allowed_tools, allowed_effect_scopes, role),
      "verification_contract" =>
        verification_contract(role, validation_contract, evidence_contract),
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  def work_role(arguments, tool_name \\ nil)

  def work_role(arguments, tool_name) when is_map(arguments) do
    arguments = RuntimeContracts.string_keys(arguments)

    normalize_role(RuntimeContracts.value(arguments, "work_role")) ||
      skill_role(
        RuntimeContracts.text(
          arguments,
          "target_skill",
          RuntimeContracts.text(arguments, "skill")
        )
      ) ||
      normalize_role(RuntimeContracts.value(arguments, "role")) ||
      tool_default_role(tool_name)
  end

  def work_role(_arguments, tool_name), do: tool_default_role(tool_name)

  defp parent_boundary(context, plan_contract, action_contract, attrs) do
    task = RuntimeContracts.normalize_map(attrs["task"])

    %{
      "task_id" => RuntimeContracts.value(context, "task_id") || task["id"],
      "task_ref" => RuntimeContracts.value(context, "task_ref") || task["ref"],
      "parent_task_id" => RuntimeContracts.value(context, "parent_task_id") || task["parent_id"],
      "agent_id" => RuntimeContracts.value(context, "agent_id") || attrs["agent_id"],
      "delegated_from_agent_id" => RuntimeContracts.value(context, "delegated_from_agent_id"),
      "session_id" => RuntimeContracts.value(context, "session_id"),
      "run_id" => RuntimeContracts.value(context, "run_id"),
      "plan_id" => plan_contract["plan_id"],
      "action_contract_id" => action_contract["contract_id"],
      "action_effect_scope" => action_contract["effect_scope"]
    }
    |> RuntimeContracts.reject_empty()
  end

  defp child_boundary(child_ref, target_skill, role, tool_name) do
    %{
      "child_ref" => child_ref,
      "target_agent_id" => if(tool_name in ["invoke_agent", "start_agent_work"], do: child_ref),
      "target_skill" => target_skill,
      "work_role" => role,
      "execution_mode" => execution_mode(tool_name)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp job_contract(arguments, target_skill, allowed_tools, validation_contract) do
    instructions = RuntimeContracts.text(arguments, "instructions")

    %{
      "target_role" => RuntimeContracts.text(arguments, "target_role"),
      "target_skill" => target_skill,
      "required_capabilities" =>
        RuntimeContracts.normalize_string_list(arguments["required_capabilities"]),
      "input_artifacts" => RuntimeContracts.normalize_string_list(arguments["input_artifacts"]),
      "expected_output_artifacts" =>
        RuntimeContracts.normalize_string_list(arguments["expected_output_artifacts"]),
      "handoff_requirements" =>
        RuntimeContracts.normalize_string_list(arguments["handoff_requirements"]),
      "allowed_tools" => allowed_tools,
      "capability_contract" => RuntimeContracts.normalize_map(arguments["capability_contract"]),
      "max_autonomy" => RuntimeContracts.text(arguments, "max_autonomy"),
      "validation_contract" => validation_contract,
      "instructions_digest" =>
        if(instructions, do: RuntimeContracts.stable_id("instructions", [instructions])),
      "instructions_preview" => preview(instructions, 360)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp authority_boundary(context, allowed_tools, allowed_effect_scopes, role) do
    %{
      "task_scope" => "current_task",
      "current_task_id" => RuntimeContracts.value(context, "task_id"),
      "parent_task_read" => RuntimeContracts.value(context, "parent_task_id"),
      "allowed_tools" => allowed_tools,
      "allowed_effect_scopes" => allowed_effect_scopes,
      "may_update_parent_final_status" => false,
      "may_create_continuation_tasks" => false,
      "may_delegate_further" => false,
      "parent_integration_required" => true,
      "durable_output_kinds" => durable_output_kinds(role)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp verification_contract(role, validation_contract, evidence_contract) do
    %{
      "gate_tool" => "route_verification_review",
      "verifier_required" => role != "verifier",
      "verifier_role" => "verifier",
      "parent_final_decision_required" => true,
      "evidence_contract" => evidence_contract,
      "acceptance_criteria" =>
        validation_contract ||
          "Child must return concrete evidence, unresolved risks, and a concise pass/fail judgment."
    }
    |> RuntimeContracts.reject_empty()
  end

  defp child_ref(arguments, attrs) do
    first_present([
      RuntimeContracts.value(arguments, "target_agent_id"),
      RuntimeContracts.value(arguments, "agent_id"),
      RuntimeContracts.value(arguments, "agent_ref"),
      RuntimeContracts.value(arguments, "handle"),
      RuntimeContracts.value(arguments, "role"),
      RuntimeContracts.value(attrs, "target_agent_id"),
      RuntimeContracts.value(attrs, "agent_id")
    ])
  end

  defp execution_mode("invoke_agent"), do: "persisted_agent"
  defp execution_mode("start_agent_work"), do: "persisted_agent"
  defp execution_mode("continue_agent_work"), do: "persisted_agent"
  defp execution_mode("delegate_to_agent"), do: "ephemeral_sub_agent"
  defp execution_mode(_tool_name), do: "agent_orchestration"

  defp allowed_effect_scopes([], plan_contract) do
    plan_contract
    |> RuntimeContracts.value("allowed_effect_scopes")
    |> RuntimeContracts.normalize_string_list()
    |> Enum.filter(
      &(&1 in ~w(read_only session_ephemeral task_durable sandbox_durable workspace_durable))
    )
  end

  defp allowed_effect_scopes(allowed_tools, _plan_contract) do
    allowed_tools
    |> Enum.map(&ActionContract.effect_scope/1)
    |> Enum.reject(&(&1 in ["unknown", "agent_orchestration", "external_side_effect"]))
    |> Enum.uniq()
  end

  defp evidence_contract(attrs, plan_contract) do
    direct = RuntimeContracts.normalize_map(attrs["evidence_contract"])

    if direct == %{} do
      plan_contract
      |> RuntimeContracts.value("verification_contract")
      |> RuntimeContracts.normalize_map()
      |> RuntimeContracts.value("evidence_contract")
      |> RuntimeContracts.normalize_map()
    else
      direct
    end
  end

  defp durable_output_kinds("verifier"), do: ~w(verification_report critique handoff)
  defp durable_output_kinds("researcher"), do: ~w(research_note handoff)
  defp durable_output_kinds("critic"), do: ~w(critique verification_report handoff)
  defp durable_output_kinds(_role), do: ~w(handoff workflow_contract node_heartbeat)

  defp normalize_role(value) do
    role = normalize_string(value)

    if role in @work_roles do
      role
    else
      nil
    end
  end

  defp skill_role(skill) when skill in @verifier_skills, do: "verifier"
  defp skill_role(skill) when skill in @researcher_skills, do: "researcher"
  defp skill_role(skill) when skill in @critic_skills, do: "critic"
  defp skill_role(_skill), do: nil

  defp tool_default_role(tool_name) when tool_name in @orchestration_tools, do: "worker"
  defp tool_default_role(_tool_name), do: "worker"

  defp first_present(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.find(& &1)
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp preview(nil, _limit), do: nil
  defp preview(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp preview(value, limit), do: value |> inspect() |> String.slice(0, limit)

  defp maybe_put_argument(arguments, _key, value) when value in [nil, ""], do: arguments

  defp maybe_put_argument(arguments, key, value) do
    Map.put_new(arguments, key, value)
  end
end
