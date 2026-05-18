defmodule Holt.Tasks.AttributesTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.Attributes

  test "dependency links read depends_on_task_ids only" do
    assert [%{"target_id" => "HW-1", "type" => "depends_on"}] =
             Attributes.dependency_links(%{"depends_on_task_ids" => ["HW-1"]})

    assert Attributes.dependency_links(%{"depends_on_task_id" => "HW-1"}) == []
  end

  test "assignee maps read agent_id as the canonical identifier" do
    assert [
             %{
               "id" => "agent-1",
               "agent_id" => "agent-1",
               "display_name" => "Agent One"
             }
           ] =
             Attributes.normalize_assignees(%{
               "agent_id" => "agent-1",
               "display_name" => "Agent One"
             })

    assert Attributes.normalize_assignees(%{"id" => "agent-1"}) == []

    assert [%{"display_name" => "agent-1"}] =
             Attributes.normalize_assignees(%{"agent_id" => "agent-1", "name" => "Legacy"})
  end

  test "normalizers reject atom-keyed nested maps instead of converting them" do
    assert Attributes.normalize_labels(%{name: "legacy"}) == []
    assert Attributes.normalize_assignees(%{agent_id: "agent-1"}) == []
    assert Attributes.normalize_links([%{target_id: "task-1"}]) == []
    assert Attributes.normalize_recurrence(%{frequency: "daily"}) == nil
    assert Attributes.normalize_agent_policy(%{auto_continue: true}) == %{}
    assert Attributes.normalize_metadata(%{source: "legacy"}) == %{}
  end
end
