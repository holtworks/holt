defmodule Holt.Tasks.TaskMemoryTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.TaskMemory

  describe "record_artifact/3" do
    test "rejects atom-keyed artifact contracts" do
      root = tmp_root()

      assert {:error, :invalid_task_memory_attrs} =
               TaskMemory.record_artifact(root, task(), %{content: "memory"})

      assert {:error, :invalid_task_memory_attrs} =
               TaskMemory.record_artifact(root, task(), %{
                 "content" => "memory",
                 "metadata" => %{source: "atom"}
               })
    end

    test "rejects obsolete artifact fields" do
      root = tmp_root()

      assert {:error, {:obsolete_task_memory_attr, "body", "content"}} =
               TaskMemory.record_artifact(root, task(), %{"body" => "legacy body"})

      assert {:error, {:obsolete_task_memory_attr, "action_name", "action"}} =
               TaskMemory.record_artifact(root, task(), %{
                 "content" => "memory",
                 "action_name" => "old_action"
               })
    end

    test "requires canonical content" do
      assert {:error, :missing_artifact_content} =
               TaskMemory.record_artifact(tmp_root(), task(), %{"kind" => "handoff"})
    end
  end

  describe "context_packet/3" do
    test "does not parse numeric strings as limits" do
      root = tmp_root()

      assert {:ok, first} =
               TaskMemory.record_artifact(root, task(), %{
                 "artifact_ref" => "artifact_1",
                 "content" => "first"
               })

      assert {:ok, _second} =
               TaskMemory.record_artifact(root, task(), %{
                 "artifact_ref" => "artifact_2",
                 "content" => "second"
               })

      assert {:ok, packet} = TaskMemory.context_packet(root, task(), %{"limit" => "1"})

      assert first["artifact_ref"] in packet["artifact_refs"]
      assert length(packet["artifact_refs"]) == 2
    end
  end

  defp tmp_root do
    Path.join(System.tmp_dir!(), "holt_task_memory_test_#{System.unique_integer([:positive])}")
  end

  defp task do
    %{
      "id" => "task_1",
      "ref" => "HOLT-1",
      "title" => "Memory task",
      "status" => "open"
    }
  end
end
