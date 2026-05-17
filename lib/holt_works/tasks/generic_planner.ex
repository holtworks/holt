defmodule HoltWorks.Tasks.GenericPlanner do
  @moduledoc """
  Generic five-phase planner for local task-agent work.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.{ActionContract, RuntimeContracts}

  @schema_version "holtworks_generic_work_graph/v1"

  @phase_tools %{
    "research" => ~w(
      list_tasks get_task load_teammate_runtime list_task_specs get_task_spec
      read_task_memory_artifact list_files read_file search_files search_memory
      list_user_memories search_user_memory recall_project_memory read_project_memory
      search_web fetch_url
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
      continue_agent_work write_file append_file run_command action_runtime_envelope
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
    attrs = RuntimeContracts.string_keys(attrs)
    steps = plan_steps(attrs)
    task = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "task"))
    plan_contract = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "plan_contract"))

    %{
      "schema_version" => @schema_version,
      "graph_id" =>
        RuntimeContracts.stable_id("generic_plan", [
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
    |> RuntimeContracts.reject_empty()
  end

  def build(_attrs), do: build(%{})

  def plan_steps(attrs \\ %{})

  def plan_steps(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    allowed_tools = allowed_tools(attrs)

    workflow_constraints =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "workflow_constraints"))

    evidence_contract =
      RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "evidence_contract"))

    phase_specs(workflow_constraints, evidence_contract)
    |> Enum.map(fn spec ->
      tools =
        spec
        |> RuntimeContracts.value("allowed_tools")
        |> RuntimeContracts.normalize_string_list()
        |> filter_allowed_tools(allowed_tools)

      spec
      |> Map.put("allowed_tools", tools)
      |> Map.put("allowed_effect_scopes", effect_scopes_for_tools(tools))
      |> RuntimeContracts.reject_empty()
    end)
  end

  def plan_steps(_attrs), do: plan_steps(%{})

  defp allowed_tools(attrs) do
    explicit =
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(attrs, "allowed_tools"))

    plan = RuntimeContracts.normalize_map(RuntimeContracts.value(attrs, "plan_contract"))

    plan_tools =
      RuntimeContracts.normalize_string_list(RuntimeContracts.value(plan, "allowed_tools"))

    cond do
      explicit != [] -> explicit
      plan_tools != [] -> plan_tools
      true -> []
    end
  end

  defp phase_specs(workflow_constraints, evidence_contract) do
    [
      phase(
        "research",
        1,
        "Understand the task, constraints, current state, and reusable memory before acting.",
        @phase_tools["research"],
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
        @phase_tools["propose"],
        ["context_summary", "constraints", "known_risks"],
        ["action_proposal", "verification_plan", "delegation_plan"],
        ["action is scoped", "verification criteria are explicit"],
        workflow_constraints,
        evidence_contract
      ),
      phase(
        "act",
        3,
        "Execute the approved scoped action through the allowed task tool surface.",
        @phase_tools["act"],
        ["action_proposal", "policy_decision", "recovery_contract"],
        ["tool_result", "changed_state", "handoff_artifact"],
        ["tool result is observed", "durable changes stay inside target policy"],
        workflow_constraints,
        evidence_contract
      ),
      phase(
        "verify",
        4,
        "Compare predicted effects with observations and route structured verification.",
        @phase_tools["verify"],
        ["tool_result", "prediction", "observation", "evidence_contract"],
        ["verification_report", "outcome_calibration", "finish_or_repair_decision"],
        ["evidence contract is satisfied or a concrete gap is named"],
        workflow_constraints,
        evidence_contract
      ),
      phase(
        "repair",
        5,
        "Recover from failed verification, policy rejection, or prediction mismatch.",
        @phase_tools["repair"],
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
         tools,
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
      "allowed_tools" => tools,
      "inputs" => inputs,
      "expected_outputs" => outputs,
      "success_criteria" => success_criteria,
      "constraints" => phase_constraints(phase, constraints, evidence),
      "failure_policy" => failure_policy(phase)
    }
  end

  defp phase_constraints("research", workflow_constraints, _evidence_contract) do
    %{
      "workflow" => RuntimeContracts.value(workflow_constraints, "workflow"),
      "required_context" => ["task", "runtime_memory", "plan_contract"]
    }
    |> RuntimeContracts.reject_empty()
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
      "directory" => RuntimeContracts.value(workflow_constraints, "directory"),
      "acceptance_criteria" => RuntimeContracts.value(workflow_constraints, "acceptance_criteria")
    }
    |> RuntimeContracts.reject_empty()
  end

  defp phase_constraints("verify", workflow_constraints, evidence_contract) do
    %{
      "test_commands" => RuntimeContracts.value(workflow_constraints, "test_commands"),
      "evidence_contract" => evidence_contract,
      "finish_condition" => RuntimeContracts.value(workflow_constraints, "finish_condition")
    }
    |> RuntimeContracts.reject_empty()
  end

  defp phase_constraints("repair", _workflow_constraints, _evidence_contract) do
    %{
      "triggered_by" => [
        "policy_rejection",
        "failed_tool_result",
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
      "allowed_tools" => step["allowed_tools"],
      "allowed_effect_scopes" => step["allowed_effect_scopes"],
      "inputs" => step["inputs"],
      "expected_outputs" => step["expected_outputs"],
      "success_criteria" => step["success_criteria"],
      "constraints" => step["constraints"],
      "failure_policy" => step["failure_policy"]
    }
    |> RuntimeContracts.reject_empty()
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

  defp filter_allowed_tools(tools, []), do: tools
  defp filter_allowed_tools(tools, allowed), do: Enum.filter(tools, &(&1 in allowed))

  defp effect_scopes_for_tools(tools) do
    tools
    |> Enum.map(&ActionContract.effect_scope/1)
    |> Enum.reject(&(&1 in [nil, "", "unknown"]))
    |> Enum.uniq()
  end
end
