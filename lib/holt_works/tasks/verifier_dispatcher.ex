defmodule HoltWorks.Tasks.VerifierDispatcher do
  @moduledoc """
  Local verifier dispatch contract for task-agent work.

  HoltWorks does not start Phoenix agent sessions here. The dispatcher claims a
  verifier assignment, builds the bounded child-agent job packet, and returns
  `start_agent_work_params` for the existing local task-agent API.
  """

  alias HoltWorks.Clock
  alias HoltWorks.Tasks.{ChildAgentContract, RuntimeContracts}

  @schema_version "holtworks_verifier_dispatch/v1"
  @started_schema_version "holtworks_verifier_dispatch_started/v1"
  @default_lease_ms 35 * 60 * 1_000
  @default_max_attempts 3
  @dispatcher_source "verifier_dispatcher"

  def build(attrs \\ %{})

  def build(attrs) when is_map(attrs) do
    attrs = RuntimeContracts.string_keys(attrs)
    task = RuntimeContracts.normalize_map(attrs["task"])
    work_graph = RuntimeContracts.normalize_map(attrs["work_graph"])

    work_graph_gate =
      RuntimeContracts.normalize_map(attrs["work_graph_gate"] || work_graph["completion_gate"])

    verification_contract = RuntimeContracts.normalize_map(attrs["verification_contract"])

    assignment =
      RuntimeContracts.normalize_map(attrs["verifier_assignment"] || attrs["assignment"])

    selected_verifier = RuntimeContracts.normalize_map(assignment["selected_verifier"])

    cond do
      verification_contract["required"] == false or work_graph_gate["can_finish"] == true ->
        idle_dispatch(task, work_graph, work_graph_gate)

      selected_verifier == %{} ->
        blocked_dispatch(task, work_graph, assignment)

      true ->
        claimed_dispatch(attrs, task, work_graph, work_graph_gate, assignment, selected_verifier)
    end
  end

  def build(_attrs), do: build(%{})

  defp idle_dispatch(task, work_graph, work_graph_gate) do
    %{
      "schema_version" => @schema_version,
      "dispatch_id" =>
        RuntimeContracts.stable_id("verifier_dispatch", [
          task["id"],
          work_graph["graph_id"],
          work_graph_gate["status"],
          "idle"
        ]),
      "status" => "idle",
      "reason" => "verification_not_required",
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "work_graph_id" => work_graph["graph_id"],
      "work_graph_gate_status" => work_graph_gate["status"],
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp blocked_dispatch(task, work_graph, assignment) do
    %{
      "schema_version" => @schema_version,
      "dispatch_id" =>
        RuntimeContracts.stable_id("verifier_dispatch", [
          task["id"],
          work_graph["graph_id"],
          assignment["assignment_id"],
          "blocked"
        ]),
      "status" => "blocked",
      "reason" => assignment["reason"] || "verifier_assignment_missing",
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "work_graph_id" => work_graph["graph_id"],
      "verifier_assignment_id" => assignment["assignment_id"],
      "assignment_result" => assignment["assignment_result"],
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp claimed_dispatch(attrs, task, work_graph, work_graph_gate, assignment, selected_verifier) do
    now = Clock.now()
    attempt = attempt(attrs)
    max_attempts = max_attempts(attrs)
    route = RuntimeContracts.normalize_map(attrs["verifier_route"] || attrs["route"])
    evidence_contract = RuntimeContracts.normalize_map(attrs["evidence_contract"])
    child_contract = child_agent_contract(attrs, task, work_graph, assignment, selected_verifier)
    lease_expires_at = DateTime.add(now, lease_ms(attrs), :millisecond)

    route_id =
      RuntimeContracts.text(
        route,
        "route_id",
        RuntimeContracts.stable_id("verifier_route", [assignment["assignment_id"]])
      )

    child_session_id = child_session_id(task, work_graph, route_id)
    allowed_tools = allowed_tools(child_contract, evidence_contract)

    start_params =
      start_agent_work_params(
        task,
        work_graph,
        selected_verifier,
        route_id,
        child_session_id,
        evidence_contract
      )

    %{
      "schema_version" => @schema_version,
      "dispatch_id" =>
        RuntimeContracts.stable_id("verifier_dispatch", [
          task["id"],
          work_graph["graph_id"],
          assignment["assignment_id"],
          route_id,
          attempt
        ]),
      "status" => "claimed",
      "source" => @dispatcher_source,
      "task_id" => task["id"],
      "task_ref" => task["ref"],
      "work_graph_id" => work_graph["graph_id"],
      "work_graph_gate_status" => work_graph_gate["status"],
      "route_id" => route_id,
      "attempt" => attempt,
      "max_attempts" => max_attempts,
      "claimed_at" => DateTime.to_iso8601(now),
      "lease_expires_at" => DateTime.to_iso8601(lease_expires_at),
      "lease_ms" => lease_ms(attrs),
      "child_session_id" => child_session_id,
      "target_agent_id" => selected_verifier["agent_id"],
      "target_agent_ref" => selected_verifier["agent_ref"],
      "target_agent_handle" => selected_verifier["handle"],
      "execution_mode" => selected_verifier["execution_mode"],
      "verifier_assignment_id" => assignment["assignment_id"],
      "assignment_result" => assignment["assignment_result"],
      "allowed_tools" => allowed_tools,
      "evidence_contract" => evidence_contract,
      "child_agent_contract" => child_contract,
      "start_agent_work_params" => start_params,
      "started_event" =>
        started_event(route_id, attempt, child_session_id, child_contract, allowed_tools),
      "permissions" => verifier_permissions(allowed_tools),
      "dispatch_mode" => "manual_start_agent_work",
      "created_at" => Clock.iso_now()
    }
    |> RuntimeContracts.reject_empty()
  end

  defp child_agent_contract(attrs, task, work_graph, assignment, selected_verifier) do
    evidence_contract = RuntimeContracts.normalize_map(attrs["evidence_contract"])

    ChildAgentContract.build(%{
      "tool_name" => "start_agent_work",
      "task" => task,
      "evidence_contract" => evidence_contract,
      "context" => %{
        "task_id" => task["id"],
        "task_ref" => task["ref"],
        "agent_id" => selected_verifier["agent_id"],
        "run_id" => work_graph["graph_id"]
      },
      "arguments" => %{
        "target_agent_id" => selected_verifier["agent_id"],
        "work_role" => "verifier",
        "allowed_tools" => allowed_tools(%{}, evidence_contract),
        "expected_output_artifacts" => ["verification_report"],
        "validation_contract" =>
          "Submit route_verification_review against the evidence contract.",
        "instructions" => verifier_instructions(assignment, work_graph, evidence_contract)
      }
    })
  end

  defp start_agent_work_params(
         task,
         work_graph,
         selected_verifier,
         route_id,
         child_session_id,
         evidence_contract
       ) do
    agent_ids =
      case selected_verifier["execution_mode"] do
        "persisted_agent" -> RuntimeContracts.normalize_string_list(selected_verifier["agent_id"])
        _mode -> []
      end

    %{
      "task_id" => task["ref"] || task["id"],
      "graph_id" => work_graph["task_graph_id"] || work_graph["id"],
      "node_key" => "verify",
      "agent_ids" => agent_ids,
      "source" => @dispatcher_source,
      "request_id" => route_id,
      "verifier_route_id" => route_id,
      "child_session_id" => child_session_id,
      "message" => verifier_message(task, work_graph, route_id, evidence_contract)
    }
    |> RuntimeContracts.reject_empty()
  end

  defp verifier_message(task, work_graph, route_id, evidence_contract) do
    required_groups =
      evidence_contract
      |> RuntimeContracts.value("required_check_groups")
      |> List.wrap()
      |> Enum.map(fn group ->
        group = RuntimeContracts.normalize_map(group)
        "#{group["group_id"]}: #{Enum.join(group["any_of"] || [], ", ")}"
      end)
      |> case do
        [] -> "none"
        rows -> Enum.join(rows, "; ")
      end

    """
    Verify task #{task["ref"] || task["id"]} before integration.

    Verifier route: #{route_id}
    Work graph: #{work_graph["graph_id"] || work_graph["id"]}
    Required check groups: #{required_groups}

    Inspect task artifacts and worker handoff evidence. Submit route_verification_review with structured checks, changed_files, evidence, and surface statuses. Do not mark the parent task done directly.
    """
    |> String.trim()
  end

  defp verifier_instructions(assignment, work_graph, evidence_contract) do
    """
    Inspect the assigned work graph before integration.

    Assignment: #{assignment["assignment_id"]}
    Work product: #{assignment["work_product_ref"] || work_graph["graph_id"]}
    Evidence contract: #{Jason.encode!(evidence_contract)}

    Return a structured verification report through route_verification_review.
    """
    |> String.trim()
  end

  defp started_event(route_id, attempt, child_session_id, child_contract, allowed_tools) do
    %{
      "schema_version" => @started_schema_version,
      "status" => "claimed",
      "route_id" => route_id,
      "attempt" => attempt,
      "child_contract_id" => child_contract["child_contract_id"] || child_contract["contract_id"],
      "child_session_id" => child_session_id,
      "allowed_tools" => allowed_tools,
      "source" => @dispatcher_source
    }
    |> RuntimeContracts.reject_empty()
  end

  defp verifier_permissions(tools) do
    %{
      "tool_policy" => "allowlist",
      "tool_list" => tools,
      "always_allowed" => Enum.uniq(["ask_user" | tools]),
      "approval_mode" => "auto_approve_read_only",
      "file_write" => "blocked",
      "destructive_command" => "blocked",
      "may_mark_parent_done" => false,
      "may_delegate_further" => false
    }
  end

  defp allowed_tools(child_contract, evidence_contract) do
    contract_tools =
      child_contract
      |> RuntimeContracts.value("job_contract")
      |> RuntimeContracts.normalize_map()
      |> RuntimeContracts.value("allowed_tools")
      |> RuntimeContracts.normalize_string_list()

    evidence_tools =
      RuntimeContracts.normalize_string_list(evidence_contract["allowed_verifier_tools"])

    (contract_tools ++
       evidence_tools ++
       ~w(get_task list_task_specs get_task_spec read_task_memory_artifact load_teammate_runtime route_verification_review))
    |> RuntimeContracts.normalize_string_list()
  end

  defp child_session_id(task, work_graph, route_id) do
    [
      "verifier",
      task["ref"] || task["id"],
      work_graph["graph_id"] || work_graph["id"],
      route_id
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(":")
  end

  defp attempt(attrs) do
    attrs
    |> RuntimeContracts.value("attempt")
    |> RuntimeContracts.integer()
    |> case do
      int when int > 0 -> int
      _int -> 1
    end
  end

  defp max_attempts(attrs) do
    attrs
    |> RuntimeContracts.value("max_attempts")
    |> RuntimeContracts.integer()
    |> case do
      int when int > 0 -> int
      _int -> @default_max_attempts
    end
  end

  defp lease_ms(attrs) do
    attrs
    |> RuntimeContracts.value("lease_ms")
    |> RuntimeContracts.integer()
    |> case do
      int when int > 0 -> int
      _int -> @default_lease_ms
    end
  end
end
