defmodule Holt.Tasks.GenericPlanner do
  @moduledoc """
  Generic five-phase planner for local task-agent work.
  """

  alias Holt.Clock
  alias Holt.Tasks.ActionContract

  @schema_version "holt_generic_work_graph/v1"

  @phase_actions %{
    "research" => ~w(
      list_tasks get_task load_teammate_runtime list_task_specs get_task_spec
      read_task_memory_artifact list read search recall
      list_user_memories search_user_memory recall_project_memory read_project_memory
      search_web fetch
      work_graph work_graph_schedule agent_dispatch_plan team_orchestration
    ),
    "propose" => ~w(
      add_comment save_task_spec save_teammate_memory remember_for_project save_plan save_research
      create_task_graph advance_task_graph
      action_contract plan_contract plan_gate action_preflight consequence_gate
      work_graph_budget child_agent_contract agent_dispatch_plan
    ),
    "act" => ~w(
      update_task add_comment save_task_spec save_teammate_memory start_agent_work
      continue_agent_work write append run action_runtime_envelope
    ),
    "verify" => ~w(
      get_task list_task_specs get_task_spec read_task_memory_artifact route_verification_review
      get_evidence_contract plan_verifier_route complete_action_runtime_envelope
      work_graph_gate work_graph_schedule verification_contract verifier_assignment
      verifier_dispatch verifier_calibration
    ),
    "repair" => ~w(
      get_task load_teammate_runtime add_comment update_task save_task_spec save_teammate_memory
      continue_agent_work action_runtime_envelope complete_action_runtime_envelope
    )
  }

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> build_canonical(input)
      {:error, reason} -> rejected_plan(attrs, reason)
    end
  end

  def build(_attrs), do: rejected_plan(%{}, "invalid_attrs")

  def plan_steps(attrs \\ %{})

  def plan_steps(attrs) when is_map(attrs) do
    case input(attrs) do
      {:ok, input} -> plan_steps_for_input(input)
      {:error, reason} -> raise ArgumentError, "invalid generic planner attrs: #{reason}"
    end
  end

  def plan_steps(_attrs), do: raise(ArgumentError, "invalid generic planner attrs: invalid_attrs")

  defp input(attrs) do
    with :ok <- canonical_attrs(attrs),
         {:ok, task} <- optional_map_field(attrs, "task", "invalid_task"),
         {:ok, plan_contract} <-
           optional_map_field(attrs, "plan_contract", "invalid_plan_contract"),
         {:ok, workflow_constraints} <-
           optional_map_field(attrs, "workflow_constraints", "invalid_workflow_constraints"),
         {:ok, evidence_contract} <-
           optional_map_field(attrs, "evidence_contract", "invalid_evidence_contract"),
         {:ok, allowed_actions} <- plan_contract_allowed_actions(plan_contract) do
      {:ok,
       %{
         task: task,
         plan_contract: plan_contract,
         workflow_constraints: workflow_constraints,
         evidence_contract: evidence_contract,
         allowed_actions: allowed_actions
       }}
    end
  end

  defp build_canonical(input) do
    steps = plan_steps_for_input(input)
    task = input.task
    plan_contract = input.plan_contract

    %{
      "schema_version" => @schema_version,
      "graph_id" =>
        stable_id("generic_plan", [
          task["id"],
          plan_contract["plan_id"],
          steps
        ]),
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "plan_contract_id" => plan_contract["plan_id"],
      "node_types" => ~w(research propose act verify repair),
      "nodes" => Enum.map(steps, &typed_node/1),
      "edges" => edges(),
      "control_policy" => %{
        "entry_node" => "research",
        "normal_path" => ~w(research propose act verify),
        "repair_loop" => ~w(verify repair act verify),
        "finish_node" => "verify"
      },
      "generated_at" => Clock.iso_now()
    }
    |> compact()
  end

  defp rejected_plan(attrs, reason) do
    %{
      "schema_version" => @schema_version,
      "graph_id" => stable_id("generic_plan", [reason, attrs]),
      "status" => "rejected",
      "reason" => reason,
      "generated_at" => Clock.iso_now()
    }
  end

  defp plan_steps_for_input(input) do
    input.workflow_constraints
    |> phase_specs(input.evidence_contract)
    |> Enum.map(&plan_step(&1, input.allowed_actions))
  end

  defp plan_step(spec, allowed_actions) do
    actions =
      spec
      |> Map.fetch!("allowed_actions")
      |> filter_allowed_actions(allowed_actions)

    spec
    |> Map.put("allowed_actions", actions)
    |> Map.put("allowed_effect_scopes", effect_scopes_for_actions(actions))
    |> compact()
  end

  defp phase_specs(workflow_constraints, evidence_contract) do
    [
      phase(
        "research",
        1,
        "Understand the task, constraints, current state, and reusable memory before acting.",
        @phase_actions["research"],
        ["assigned_task", "parent_context", "runtime_memory", "source_artifacts"],
        ["context_summary", "constraints", "known_risks"],
        ["objective and boundaries are loaded", "current facts are checked when needed"],
        workflow_constraints,
        evidence_contract
      ),
      phase(
        "propose",
        2,
        "Choose the smallest useful next action and state how it will be verified.",
        @phase_actions["propose"],
        ["context_summary", "constraints", "known_risks"],
        ["action_proposal", "verification_plan", "delegation_plan"],
        ["action is scoped", "verification criteria are explicit"],
        workflow_constraints,
        evidence_contract
      ),
      phase(
        "act",
        3,
        "Execute the approved scoped action through the allowed task action surface.",
        @phase_actions["act"],
        ["action_proposal", "policy_decision", "recovery_contract"],
        ["action_result", "changed_state", "handoff_artifact"],
        ["action result is observed", "durable changes stay inside target policy"],
        workflow_constraints,
        evidence_contract
      ),
      phase(
        "verify",
        4,
        "Compare predicted effects with observations and route structured verification.",
        @phase_actions["verify"],
        ["action_result", "prediction", "observation", "evidence_contract"],
        ["verification_report", "outcome_calibration", "finish_or_repair_decision"],
        ["evidence contract is satisfied or a concrete gap is named"],
        workflow_constraints,
        evidence_contract
      ),
      phase(
        "repair",
        5,
        "Recover from failed verification, policy rejection, or prediction mismatch.",
        @phase_actions["repair"],
        ["failed_verification", "prediction_error", "rollback_plan"],
        ["repair_action", "updated_lesson", "new_verification_plan"],
        ["failure mode is addressed before retry", "lesson is persisted for the pattern"],
        workflow_constraints,
        evidence_contract
      )
    ]
  end

  defp phase(
         phase,
         order,
         objective,
         actions,
         inputs,
         outputs,
         success_criteria,
         constraints,
         evidence
       ) do
    %{
      "step_id" => phase,
      "phase" => phase,
      "node_type" => phase,
      "order" => order,
      "objective" => objective,
      "allowed_actions" => actions,
      "inputs" => inputs,
      "expected_outputs" => outputs,
      "success_criteria" => success_criteria,
      "constraints" => phase_constraints(phase, constraints, evidence),
      "failure_policy" => failure_policy(phase)
    }
  end

  defp phase_constraints("research", workflow_constraints, _evidence_contract) do
    %{
      "workflow" => workflow_constraints["workflow"],
      "required_context" => ["task", "runtime_memory", "plan_contract"]
    }
    |> compact()
  end

  defp phase_constraints("propose", _workflow_constraints, _evidence_contract) do
    %{
      "must_name_effect_scope" => true,
      "must_name_verification_plan" => true,
      "must_name_recovery_contract_for_mutation" => true
    }
  end

  defp phase_constraints("act", workflow_constraints, _evidence_contract) do
    %{
      "target_policy" => "current_task_or_explicit_workspace_target",
      "directory" => workflow_constraints["directory"],
      "acceptance_criteria" => workflow_constraints["acceptance_criteria"]
    }
    |> compact()
  end

  defp phase_constraints("verify", workflow_constraints, evidence_contract) do
    %{
      "test_commands" => workflow_constraints["test_commands"],
      "evidence_contract" => evidence_contract,
      "finish_condition" => workflow_constraints["finish_condition"]
    }
    |> compact()
  end

  defp phase_constraints("repair", _workflow_constraints, _evidence_contract) do
    %{
      "triggered_by" => [
        "policy_rejection",
        "failed_action_result",
        "prediction_mismatch",
        "verification_gap"
      ],
      "must_update_pattern_lesson_on_repeated_failure" => true
    }
  end

  defp failure_policy("research"), do: "ask_or_block_if_required_context_missing"
  defp failure_policy("propose"), do: "revise_proposal_until_policy_addressed"
  defp failure_policy("act"), do: "observe_failure_and_enter_repair"
  defp failure_policy("verify"), do: "enter_repair_or_route_human_review"
  defp failure_policy("repair"), do: "retry_once_with_new_prediction_or_block"

  defp typed_node(step) do
    %{
      "node_id" => step["phase"],
      "node_key" => step["phase"],
      "kind" => step["phase"],
      "phase" => step["phase"],
      "node_type" => step["node_type"],
      "order" => step["order"],
      "label" => titleize_phase(step["phase"]),
      "status" => if(step["phase"] == "research", do: "scheduled", else: "pending"),
      "objective" => step["objective"],
      "allowed_actions" => step["allowed_actions"],
      "allowed_effect_scopes" => step["allowed_effect_scopes"],
      "inputs" => step["inputs"],
      "expected_outputs" => step["expected_outputs"],
      "success_criteria" => step["success_criteria"],
      "constraints" => step["constraints"],
      "failure_policy" => step["failure_policy"]
    }
    |> compact()
  end

  defp titleize_phase("research"), do: "Research"
  defp titleize_phase("propose"), do: "Propose"
  defp titleize_phase("act"), do: "Act"
  defp titleize_phase("verify"), do: "Verify"
  defp titleize_phase("repair"), do: "Repair"
  defp titleize_phase(phase), do: phase

  defp edges do
    [
      edge("research", "propose", "context_ready"),
      edge("propose", "act", "proposal_gated"),
      edge("act", "verify", "action_observed"),
      edge("verify", "repair", "verification_failed"),
      edge("repair", "act", "repair_ready")
    ]
  end

  defp edge(from, to, condition) do
    %{
      "from" => from,
      "to" => to,
      "condition" => condition
    }
  end

  defp filter_allowed_actions(actions, []), do: actions
  defp filter_allowed_actions(actions, allowed), do: Enum.filter(actions, &(&1 in allowed))

  defp effect_scopes_for_actions(actions) do
    actions
    |> Enum.map(&ActionContract.effect_scope/1)
    |> Enum.reject(&(&1 in [nil, "", "unknown"]))
    |> Enum.uniq()
  end

  defp plan_contract_allowed_actions(plan_contract) do
    case Map.fetch(plan_contract, "allowed_actions") do
      {:ok, actions} -> string_list(actions, "invalid_plan_contract")
      :error -> {:ok, []}
    end
  end

  defp optional_map_field(attrs, key, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> canonical_map(value, reason)
      {:ok, _value} -> {:error, reason}
      :error -> {:ok, %{}}
    end
  end

  defp string_list(values, reason) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, values}
    else
      {:error, reason}
    end
  end

  defp string_list(_values, reason), do: {:error, reason}

  defp canonical_attrs(attrs) do
    if Enum.all?(attrs, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, "invalid_attrs"}
    end
  end

  defp canonical_map(map, reason), do: canonical_keyed_map(map, reason)

  defp canonical_keyed_map(map, reason) do
    if canonical_map?(map), do: {:ok, map}, else: {:error, reason}
  end

  defp canonical_map?(map) when is_map(map) do
    Enum.all?(map, fn
      {key, value} when is_binary(key) -> canonical_value?(value)
      {_key, _value} -> false
    end)
  end

  defp canonical_value?(value) when is_map(value), do: canonical_map?(value)
  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

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
