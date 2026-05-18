defmodule Holt.Tasks.VerifierAssignmentTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.VerifierAssignment

  test "assigns an independent verifier from canonical inputs" do
    assignment =
      VerifierAssignment.assign(%{
        "work_graph" => %{"id" => "graph-1"},
        "work_graph_gate" => %{"status" => "blocked"},
        "actor_agent_ids" => ["agent_worker"],
        "available_agents" => [
          agent("agent_worker", "worker"),
          agent("agent_verify", "verifier")
        ],
        "verifier_quality" => [
          %{
            "verifier_agent_id" => "agent_verify",
            "accuracy" => 0.9,
            "matched_count" => 2,
            "missed_failure_count" => 0,
            "false_block_count" => 0
          }
        ]
      })

    assert assignment["schema_version"] == "holt_verifier_assignment/v1"
    assert assignment["assignment_result"] == "assigned"
    assert assignment["selected_verifier"]["agent_id"] == "agent_verify"
    assert assignment["selected_verifier"]["independence_status"] == "independent"
    assert assignment["work_graph_gate_status"] == "blocked"

    worker_candidate = candidate(assignment, "agent_worker")
    assert worker_candidate["eligible"] == false
    assert worker_candidate["independence_status"] == "same_actor"

    verifier_candidate = candidate(assignment, "agent_verify")
    assert verifier_candidate["eligible"] == true
    assert verifier_candidate["quality_score_adjustment"] > 0
  end

  test "rejects atom-keyed work graph input" do
    assignment =
      VerifierAssignment.assign(%{
        :work_graph => %{
          "id" => "graph-legacy",
          "completion_gate" => %{"status" => "approved"}
        },
        "allow_ephemeral_verifier" => false,
        "available_agents" => [agent("agent_verify", "verifier")]
      })

    assert %{
             "assignment_result" => "rejected",
             "reason" => "invalid_attrs"
           } = assignment
  end

  test "rejects string numeric verifier quality" do
    assignment =
      VerifierAssignment.assign(%{
        "work_graph" => %{"id" => "graph-1"},
        "work_graph_gate" => %{"status" => "blocked"},
        "available_agents" => [agent("agent_verify", "verifier")],
        "verifier_quality" => [
          %{
            "verifier_agent_id" => "agent_verify",
            "accuracy" => "0.99",
            "matched_count" => "5",
            "missed_failure_count" => "2",
            "false_block_count" => "1"
          }
        ]
      })

    assert %{
             "assignment_result" => "rejected",
             "reason" => "invalid_verifier_quality"
           } = assignment
  end

  test "rejects non-boolean ephemeral verifier policy" do
    assignment =
      VerifierAssignment.assign(%{
        "work_graph" => %{"id" => "graph-1"},
        "allow_ephemeral_verifier" => "false",
        "available_agents" => [agent("agent_verify", "verifier")]
      })

    assert %{
             "assignment_result" => "rejected",
             "reason" => "invalid_allow_ephemeral_verifier"
           } = assignment
  end

  test "rejects non-map attrs" do
    assert %{
             "schema_version" => "holt_verifier_assignment/v1",
             "assignment_result" => "rejected",
             "reason" => "invalid_attrs"
           } = VerifierAssignment.assign([])
  end

  defp agent(agent_id, work_role) do
    %{
      "agent_id" => agent_id,
      "display_name" => agent_id,
      "work_role" => work_role,
      "status" => "active"
    }
  end

  defp candidate(assignment, agent_id) do
    Enum.find(assignment["eligible_verifiers"], &(&1["agent_id"] == agent_id))
  end
end
