defmodule Holt.Tasks.FacadeContractTest do
  use ExUnit.Case, async: true

  alias Holt.{Tasks, Workspace}

  @moduletag :tmp_dir

  setup %{tmp_dir: workspace} do
    Workspace.init(workspace)
    {:ok, task} = Tasks.create(%{"title" => "Facade contract"}, workspace: workspace)
    %{workspace: workspace, task: task}
  end

  test "action and plan facades reject atom-keyed attrs", %{workspace: workspace, task: task} do
    opts = [workspace: workspace]

    assert Tasks.action_session(task["ref"], %{agent_id: "agent-1"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.action_contract(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.route_action(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.plan_contract(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.action_preflight(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.consequence_gate(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.action_runtime_envelope(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.capability_route(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}
  end

  test "work graph facades reject atom-keyed attrs", %{workspace: workspace, task: task} do
    opts = [workspace: workspace]

    assert Tasks.work_graph(task["ref"], %{graph_id: "graph-1"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.work_graph_gate(task["ref"], %{graph_id: "graph-1"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.work_graph_budget(task["ref"], %{agent_id: "agent-1"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.work_graph_schedule(task["ref"], %{completed_node_ids: []}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.agent_dispatch_plan(task["ref"], %{agent_id: "agent-1"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.team_orchestration(task["ref"], %{strategy: "solo"}, opts) ==
             {:error, :invalid_attrs}
  end

  test "agent work facades reject atom-keyed attrs", %{workspace: workspace, task: task} do
    opts = [workspace: workspace]

    assert Tasks.start_agent_work(task["ref"], %{agent_id: "agent-1"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.start_agent_work_batch(%{ref: task["ref"]}, opts) == {:error, :invalid_attrs}

    assert Tasks.start_agent_work_batch(%{"tasks" => [%{ref: task["ref"]}]}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.continue_agent_work(task["ref"], %{agent_work_id: "work-1"}, opts) ==
             {:error, :invalid_attrs}
  end

  test "verification and evidence facades reject atom-keyed attrs", %{
    workspace: workspace,
    task: task
  } do
    opts = [workspace: workspace]

    assert Tasks.evidence_contract(task["ref"], %{graph_id: "graph-1"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.verification_contract(task["ref"], %{graph_id: "graph-1"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.route_verification(task["ref"], %{checks: []}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.action_approval_request(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.action_evidence_ledger(task["ref"], %{action: "get_task"}, opts) ==
             {:error, :invalid_attrs}

    assert Tasks.resolve_action_approval_request(
             %{"approval_request_id" => "req-1"},
             %{status: "approved"},
             opts
           ) ==
             {:error, :invalid_attrs}
  end

  test "mob colleague facade rejects atom-keyed attrs", %{workspace: workspace, task: task} do
    assert Tasks.schedule_mob_colleague_flow(
             task["ref"],
             %{groundwork_agent_id: "default"},
             workspace: workspace
           ) == {:error, :invalid_attrs}
  end
end
