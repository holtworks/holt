defmodule Holt.Tasks.ContextBudgetTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ContextBudget

  test "context budget forwards canonical message and action lists" do
    budget =
      ContextBudget.build(%{
        "policy" => %{"max_total_tokens" => 4_000},
        "provider_profile" => %{"context_window" => 8_000},
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "actions" => [%{"name" => "read"}]
      })

    assert budget["schema_version"] == "holt_context_budget/v1"
    assert budget["governor"]["estimated_input_tokens"] > 0
  end

  test "context budget defaults missing message and action lists explicitly" do
    budget = ContextBudget.build(%{"policy" => %{"max_total_tokens" => 4_000}})

    assert budget["governor"]["estimated_input_tokens"] <= 2
    assert budget["governor"]["action"] == "send"
  end

  test "context budget forwards invalid explicit fields to the governor" do
    budget = ContextBudget.build(%{"messages" => %{"role" => "user", "content" => "hello"}})

    assert budget["governor"] == %{
             "schema_version" => "holt_context_budget_governor/v1",
             "status" => "rejected",
             "reason" => "invalid_field:messages"
           }
  end

  test "context budget rejects atom-keyed attrs" do
    budget = ContextBudget.build(%{policy: %{"max_total_tokens" => 4_000}})

    assert budget == %{
             "schema_version" => "holt_context_budget/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end

  test "context budget rejects invalid policy fields" do
    budget = ContextBudget.build(%{"policy" => %{"max_total_tokens" => "4000"}})

    assert budget == %{
             "schema_version" => "holt_context_budget/v1",
             "status" => "rejected",
             "reason" => "invalid_field:max_total_tokens"
           }
  end

  test "context budget rejects non-map attrs" do
    assert ContextBudget.build([]) == %{
             "schema_version" => "holt_context_budget/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end
end
