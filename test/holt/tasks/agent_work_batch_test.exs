defmodule Holt.Tasks.AgentWorkBatchTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks

  test "batch agent work requires canonical task ref fields" do
    assert Tasks.start_agent_work_batch(%{"task_ref" => "HW-1"}) ==
             {:error, {:unsupported_argument, "task_ref"}}

    assert Tasks.start_agent_work_batch(%{"task_id" => "HW-1"}) ==
             {:error, {:unsupported_argument, "task_id"}}

    assert Tasks.start_agent_work_batch(%{"id" => "HW-1"}) ==
             {:error, {:unsupported_argument, "id"}}

    assert Tasks.start_agent_work_batch(%{"tickets" => [%{"ref" => "HW-1"}]}) ==
             {:error, {:unsupported_argument, "tickets"}}

    assert Tasks.start_agent_work_batch(%{"task_ids" => ["HW-1"]}) ==
             {:error, {:unsupported_argument, "task_ids"}}

    assert Tasks.start_agent_work_batch(%{"ticket_ids" => ["HW-1"]}) ==
             {:error, {:unsupported_argument, "ticket_ids"}}
  end

  test "batch item failures do not recover legacy task identifiers" do
    assert {:error,
            %{
              "failures" => [
                %{
                  "label" => "task request",
                  "reason" => "{:unsupported_argument, \"task_id\"}"
                }
              ]
            }} = Tasks.start_agent_work_batch(%{"tasks" => [%{"task_id" => "HW-1"}]})
  end
end
