defmodule Holt.Tasks.ChildAgentContract do
  @moduledoc """
  Structured contract for parent-bounded child-agent work.

  Child agents are useful only when authority, objective, expected outputs, and
  verification boundaries are explicit before the child starts.
  """

  alias Holt.Clock
  alias Holt.Tasks.ActionContract

  @schema_version "holt_child_agent_contract/v1"
  @orchestration_actions ~w(delegate_to_agent invoke_agent start_agent_work continue_agent_work)
  @work_roles ~w(worker verifier researcher critic reviewer observer coordinator planner operator executor fixer)
  @verifier_skills ~w(task.validate api.test graphql.test browser.verify route_verification_review)
  @researcher_skills ~w(research.web research)
  @critic_skills ~w(task.critique design.review code.review)

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, action} <- action_name(attrs),
         {:ok, arguments} <- optional_map(attrs, "arguments"),
         {:ok, context} <- optional_map(attrs, "context"),
         {:ok, plan_contract} <- optional_map(attrs, "plan_contract"),
         {:ok, action_contract} <- optional_map(attrs, "action_contract"),
         {:ok, action_call_id} <- optional_text(attrs, "action_call_id"),
         {:ok, child_ref} <- optional_text(arguments, "child_ref"),
         {:ok, target_agent_id} <- optional_text(arguments, "target_agent_id"),
         {:ok, target_skill} <- optional_text(arguments, "target_skill"),
         {:ok, role} <- strict_work_role(arguments, action),
         {:ok, allowed_actions} <- string_list_field(arguments, "allowed_actions"),
         {:ok, allowed_effect_scopes} <- allowed_effect_scopes(allowed_actions, plan_contract),
         {:ok, validation_contract} <- optional_text(arguments, "validation_contract"),
         {:ok, evidence_contract} <- evidence_contract(attrs, plan_contract),
         {:ok, job_contract} <-
           job_contract(arguments, target_skill, allowed_actions, validation_contract) do
      %{
        "schema_version" => @schema_version,
        "child_contract_id" =>
          stable_id("child_contract", [
            plan_contract["plan_id"],
            action_contract["contract_id"],
            action_call_id,
            action,
            child_ref,
            target_agent_id,
            target_skill,
            role,
            allowed_actions,
            validation_contract
          ]),
        "status" => "active",
        "action" => action,
        "action_call_id" => action_call_id,
        "parent" => parent_boundary(context, plan_contract, action_contract),
        "child" => child_boundary(child_ref, target_agent_id, target_skill, role, action),
        "job_contract" => job_contract,
        "authority_boundary" =>
          authority_boundary(context, allowed_actions, allowed_effect_scopes, role),
        "verification_contract" =>
          verification_contract(role, validation_contract, evidence_contract),
        "created_at" => Clock.iso_now()
      }
      |> compact()
    end
  end

  def build(_attrs), do: {:error, :invalid_child_agent_contract}

  def work_role(arguments, action_name \\ nil)

  def work_role(arguments, action_name) when is_map(arguments) do
    case relaxed_work_role(arguments) do
      nil -> inferred_work_role(arguments, action_name)
      role -> role
    end
  end

  def work_role(_arguments, action_name), do: action_default_role(action_name)

  defp parent_boundary(context, plan_contract, action_contract) do
    %{
      "task_id" => context["task_id"],
      "task_ref" => context["task_ref"],
      "parent_task_id" => context["parent_task_id"],
      "agent_id" => context["agent_id"],
      "delegated_from_agent_id" => context["delegated_from_agent_id"],
      "session_id" => context["session_id"],
      "run_id" => context["run_id"],
      "plan_id" => plan_contract["plan_id"],
      "action_contract_id" => action_contract["contract_id"],
      "action_effect_scope" => action_contract["effect_scope"]
    }
    |> compact()
  end

  defp child_boundary(child_ref, target_agent_id, target_skill, role, action_name) do
    %{
      "child_ref" => child_ref,
      "target_agent_id" => target_agent_id,
      "target_skill" => target_skill,
      "work_role" => role,
      "execution_mode" => execution_mode(action_name)
    }
    |> compact()
  end

  defp job_contract(arguments, target_skill, allowed_actions, validation_contract) do
    with {:ok, instructions} <- optional_text(arguments, "instructions"),
         {:ok, target_role} <- optional_text(arguments, "target_role"),
         {:ok, required_capabilities} <- string_list_field(arguments, "required_capabilities"),
         {:ok, input_artifacts} <- string_list_field(arguments, "input_artifacts"),
         {:ok, expected_output_artifacts} <-
           string_list_field(arguments, "expected_output_artifacts"),
         {:ok, handoff_requirements} <- string_list_field(arguments, "handoff_requirements"),
         {:ok, capability_contract} <- optional_map(arguments, "capability_contract"),
         {:ok, max_autonomy} <- optional_text(arguments, "max_autonomy") do
      contract =
        %{
          "target_role" => target_role,
          "target_skill" => target_skill,
          "required_capabilities" => required_capabilities,
          "input_artifacts" => input_artifacts,
          "expected_output_artifacts" => expected_output_artifacts,
          "handoff_requirements" => handoff_requirements,
          "allowed_actions" => allowed_actions,
          "capability_contract" => capability_contract,
          "max_autonomy" => max_autonomy,
          "validation_contract" => validation_contract,
          "instructions_digest" => instructions_digest(instructions),
          "instructions_preview" => preview(instructions, 360)
        }
        |> compact()

      {:ok, contract}
    end
  end

  defp authority_boundary(context, allowed_actions, allowed_effect_scopes, role) do
    %{
      "task_scope" => "current_task",
      "current_task_id" => context["task_id"],
      "parent_task_read" => context["parent_task_id"],
      "allowed_actions" => allowed_actions,
      "allowed_effect_scopes" => allowed_effect_scopes,
      "may_update_parent_final_status" => false,
      "may_create_continuation_tasks" => false,
      "may_delegate_further" => false,
      "parent_integration_required" => true,
      "durable_output_kinds" => durable_output_kinds(role)
    }
    |> compact()
  end

  defp verification_contract(role, validation_contract, evidence_contract) do
    %{
      "gate_action" => "route_verification_review",
      "verifier_required" => role != "verifier",
      "verifier_role" => "verifier",
      "parent_final_decision_required" => true,
      "evidence_contract" => evidence_contract,
      "acceptance_criteria" => acceptance_criteria(validation_contract)
    }
    |> compact()
  end

  defp inferred_work_role(arguments, action_name) do
    case optional_text(arguments, "target_skill") do
      {:ok, target_skill} -> inferred_skill_work_role(target_skill, action_name)
      {:error, _reason} -> action_default_role(action_name)
    end
  end

  defp inferred_skill_work_role(target_skill, action_name) do
    case skill_role(target_skill) do
      nil -> action_default_role(action_name)
      role -> role
    end
  end

  defp acceptance_criteria(nil),
    do: "Child must return concrete evidence, unresolved risks, and a concise pass/fail judgment."

  defp acceptance_criteria(""),
    do: "Child must return concrete evidence, unresolved risks, and a concise pass/fail judgment."

  defp acceptance_criteria(validation_contract), do: validation_contract

  defp execution_mode("invoke_agent"), do: "persisted_agent"
  defp execution_mode("start_agent_work"), do: "persisted_agent"
  defp execution_mode("continue_agent_work"), do: "persisted_agent"
  defp execution_mode("delegate_to_agent"), do: "ephemeral_sub_agent"
  defp execution_mode(_action_name), do: "agent_orchestration"

  defp allowed_effect_scopes([], plan_contract) do
    with {:ok, scopes} <- string_list_field(plan_contract, "allowed_effect_scopes") do
      scopes =
        Enum.filter(
          scopes,
          &(&1 in ~w(read_only session_ephemeral task_durable sandbox_durable workspace_durable))
        )

      {:ok, scopes}
    end
  end

  defp allowed_effect_scopes(allowed_actions, _plan_contract) do
    scopes =
      allowed_actions
      |> Enum.map(&ActionContract.effect_scope/1)
      |> Enum.reject(&(&1 in ["unknown", "agent_orchestration", "external_side_effect"]))
      |> Enum.uniq()

    {:ok, scopes}
  end

  defp evidence_contract(attrs, plan_contract) do
    with {:ok, direct} <- optional_map(attrs, "evidence_contract") do
      case direct do
        empty when empty == %{} ->
          plan_evidence_contract(plan_contract)

        contract ->
          {:ok, contract}
      end
    end
  end

  defp plan_evidence_contract(plan_contract) do
    with {:ok, verification_contract} <- optional_map(plan_contract, "verification_contract"),
         {:ok, evidence_contract} <- optional_map(verification_contract, "evidence_contract") do
      {:ok, evidence_contract}
    end
  end

  defp durable_output_kinds("verifier"), do: ~w(verification_report critique handoff)
  defp durable_output_kinds("researcher"), do: ~w(research_note handoff)
  defp durable_output_kinds("critic"), do: ~w(critique verification_report handoff)
  defp durable_output_kinds(_role), do: ~w(handoff workflow_contract node_heartbeat)

  defp strict_work_role(arguments, action_name) do
    case optional_text(arguments, "work_role") do
      {:ok, nil} ->
        {:ok, inferred_work_role(arguments, action_name)}

      {:ok, role} ->
        if role in @work_roles do
          {:ok, role}
        else
          {:error, {:invalid_child_agent_field, "work_role"}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp relaxed_work_role(arguments) do
    case optional_text(arguments, "work_role") do
      {:ok, role} when role in @work_roles -> role
      _result -> nil
    end
  end

  defp skill_role(skill) when skill in @verifier_skills, do: "verifier"
  defp skill_role(skill) when skill in @researcher_skills, do: "researcher"
  defp skill_role(skill) when skill in @critic_skills, do: "critic"
  defp skill_role(_skill), do: nil

  defp action_default_role(action_name) when action_name in @orchestration_actions, do: "worker"
  defp action_default_role(_action_name), do: "worker"

  defp action_name(attrs) do
    case Map.fetch(attrs, "action") do
      :error ->
        {:ok, "delegate_to_agent"}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        case value do
          "" -> {:error, {:invalid_child_agent_field, "action"}}
          action -> {:ok, action}
        end

      {:ok, _value} ->
        {:error, {:invalid_child_agent_field, "action"}}
    end
  end

  defp optional_text(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        case value do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:error, {:invalid_child_agent_field, key}}
    end
  end

  defp optional_map(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, %{}}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_child_agent_field, key}}
    end
  end

  defp string_list_field(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, []}
      {:ok, values} when is_list(values) -> string_list(values, key)
      {:ok, _value} -> {:error, {:invalid_child_agent_field, key}}
    end
  end

  defp string_list(values, key) do
    if Enum.all?(values, &binary_present?/1) do
      {:ok, Enum.map(values, &String.trim/1)}
    else
      {:error, {:invalid_child_agent_field, key}}
    end
  end

  defp instructions_digest(nil), do: nil

  defp instructions_digest(instructions),
    do: stable_id("instructions", [instructions])

  defp canonical_attrs(attrs) do
    if canonical_value?(attrs) do
      :ok
    else
      {:error, :invalid_child_agent_contract}
    end
  end

  defp canonical_value?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> canonical_value?(nested)
      {_key, _nested} -> false
    end)
  end

  defp canonical_value?(values) when is_list(values), do: Enum.all?(values, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp binary_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp binary_present?(_value), do: false

  defp preview(nil, _limit), do: nil
  defp preview(value, limit) when is_binary(value), do: String.slice(value, 0, limit)

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
