defmodule Holt.Tasks.TaskGraphsTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.TaskGraphs

  describe "create/3" do
    test "rejects atom-keyed graph contracts" do
      root = tmp_root()
      task = task()

      assert {:error, :invalid_task_graph_attrs} =
               TaskGraphs.create(root, task, %{title: "Atom keyed graph"})

      assert {:error, :invalid_task_graph_attrs} =
               TaskGraphs.create(root, task, %{
                 "nodes" => [%{node_key: "plan", kind: "plan"}]
               })
    end

    test "rejects obsolete graph and node aliases" do
      root = tmp_root()
      task = task()

      assert {:error, {:obsolete_task_graph_attr, "type", "graph_type"}} =
               TaskGraphs.create(root, task, %{"type" => "deep_concept"})

      assert {:error, {:obsolete_task_graph_attr, "key", "node_key"}} =
               TaskGraphs.create(root, task, %{
                 "nodes" => [%{"key" => "plan", "kind" => "plan"}]
               })
    end

    test "requires literal node metadata values" do
      root = tmp_root()
      task = task()

      assert {:ok, graph} =
               TaskGraphs.create(root, task, %{
                 "nodes" => [
                   %{
                     "node_key" => "plan",
                     "kind" => "plan",
                     "status" => :done,
                     "required" => "false",
                     "position" => "4",
                     "max_attempts" => "9"
                   }
                 ]
               })

      assert [node] = graph["nodes"]
      assert node["status"] == "scheduled"
      assert node["required"] == true
      assert node["position"] == 0
      assert node["max_attempts"] == 3
    end
  end

  describe "mission_control/1" do
    test "requires literal verification_required booleans" do
      relaxed_gate =
        TaskGraphs.mission_control(%{
          "verification_required" => "true",
          "nodes" => [done_node("work", "work")]
        })

      assert relaxed_gate["verification_required"] == false
      assert relaxed_gate["can_finish"] == true
      assert blocker_codes(relaxed_gate) == []

      strict_gate =
        TaskGraphs.mission_control(%{
          "verification_required" => true,
          "nodes" => [done_node("work", "work")]
        })

      assert strict_gate["verification_required"] == true
      assert strict_gate["can_finish"] == false
      assert blocker_codes(strict_gate) == ["verification_gate_not_satisfied"]
    end

    test "requires literal verification gate completion booleans" do
      blocked_gate =
        TaskGraphs.mission_control(%{
          "nodes" => [done_node("work", "work"), done_node("verify", "verification")],
          "verification_gate" => %{"required" => true, "can_finish" => "true"}
        })

      assert blocked_gate["verification_required"] == true
      assert blocked_gate["verification_satisfied"] == false
      assert blocker_codes(blocked_gate) == ["verification_gate_not_satisfied"]

      approved_gate =
        TaskGraphs.mission_control(%{
          "nodes" => [done_node("work", "work"), done_node("verify", "verification")],
          "verification_gate" => %{"required" => true, "can_finish" => true}
        })

      assert approved_gate["verification_satisfied"] == true
      assert approved_gate["can_finish"] == true
      assert blocker_codes(approved_gate) == []
    end
  end

  defp tmp_root do
    Path.join(System.tmp_dir!(), "holt_task_graphs_test_#{System.unique_integer([:positive])}")
  end

  defp task do
    %{"id" => "task_1", "ref" => "HOLT-1"}
  end

  defp done_node(id, kind) do
    %{
      "id" => id,
      "node_key" => id,
      "kind" => kind,
      "status" => "done",
      "required" => true
    }
  end

  defp blocker_codes(gate) do
    gate
    |> Map.get("blockers", [])
    |> Enum.map(& &1["code"])
  end
end
