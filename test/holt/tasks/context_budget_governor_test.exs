defmodule Holt.Tasks.ContextBudgetGovernorTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ContextBudgetGovernor

  test "builds a plan from canonical provider profile and integer limits" do
    assert %{
             "schema_version" => "holt_context_budget_governor/v1",
             "provider" => "openai",
             "model" => "gpt-5.2",
             "context_window" => 8_000,
             "hard_limit_tokens" => 7_000,
             "soft_limit_tokens" => 6_000,
             "critical_limit_tokens" => 6_500,
             "output_reserve_tokens" => 500,
             "action_reserve_tokens" => 200,
             "estimated_input_tokens" => 6_800,
             "available_tokens" => 0,
             "budget_state" => "critical",
             "action" => "compact_before_send",
             "provider_features" => %{
               "openai_server_compaction" => true,
               "provider_neutral_compaction" => true
             }
           } =
             ContextBudgetGovernor.plan(%{
               "provider_profile" => %{
                 "provider" => "openai",
                 "model" => "gpt-5.2",
                 "context_window" => 8_000
               },
               "estimated_input_tokens" => 6_800,
               "output_reserve_tokens" => 500,
               "action_reserve_tokens" => 200,
               "hard_limit_tokens" => 7_000,
               "soft_limit_tokens" => 6_000,
               "critical_limit_tokens" => 6_500
             })
  end

  test "rejects atom-keyed attrs" do
    assert %{
             "schema_version" => "holt_context_budget_governor/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } =
             ContextBudgetGovernor.plan(%{
               :provider_profile => %{
                 "provider" => "openai",
                 "model" => "gpt-5.2",
                 "context_window" => 8_000
               }
             })
  end

  test "rejects atom-keyed provider profile" do
    assert %{
             "schema_version" => "holt_context_budget_governor/v1",
             "status" => "rejected",
             "reason" => "invalid_field:provider_profile"
           } =
             ContextBudgetGovernor.plan(%{
               "provider_profile" => %{
                 provider: "openai",
                 model: "gpt-5.2",
                 context_window: 8_000
               }
             })
  end

  test "rejects string numeric limits" do
    assert %{
             "schema_version" => "holt_context_budget_governor/v1",
             "status" => "rejected",
             "reason" => "invalid_field:output_reserve_tokens"
           } =
             ContextBudgetGovernor.plan(%{
               "provider_profile" => %{
                 "provider" => "openai",
                 "model" => "gpt-5.2",
                 "context_window" => 8_000
               },
               "estimated_input_tokens" => "6800",
               "output_reserve_tokens" => "500",
               "action_reserve_tokens" => "200",
               "messages" => [%{"role" => "user", "content" => "hello"}]
             })
  end

  test "rejects string estimated input tokens" do
    assert %{
             "schema_version" => "holt_context_budget_governor/v1",
             "status" => "rejected",
             "reason" => "invalid_field:estimated_input_tokens"
           } =
             ContextBudgetGovernor.plan(%{
               "provider_profile" => %{
                 "provider" => "openai",
                 "model" => "gpt-5.2",
                 "context_window" => 8_000
               },
               "estimated_input_tokens" => "6800",
               "messages" => [%{"role" => "user", "content" => "hello"}]
             })
  end

  test "rejects non-map attrs" do
    assert ContextBudgetGovernor.plan([]) == %{
             "schema_version" => "holt_context_budget_governor/v1",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           }
  end

  test "compacts only canonical string-key messages" do
    long_content = String.duplicate("x", 3_000)

    assert [
             %{"role" => "system", "content" => "system"},
             %{"role" => "action", "content" => compacted},
             %{role: "action", content: ^long_content}
           ] =
             ContextBudgetGovernor.compact_messages(
               [
                 %{"role" => "system", "content" => "system"},
                 %{"role" => "action", "content" => long_content},
                 %{role: "action", content: long_content}
               ],
               %{"action" => "compact_before_send", "soft_limit_tokens" => 1}
             )

    assert compacted =~ "[context_budget_compacted"
  end
end
