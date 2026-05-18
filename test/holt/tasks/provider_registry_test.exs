defmodule Holt.Tasks.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ProviderRegistry

  test "builds provider profile from explicit provider" do
    assert %{
             "schema_version" => "holt_provider_profile/v1",
             "model_id" => "local-planner",
             "provider" => "local",
             "runtime_kind" => "local_planner",
             "context_window" => 16_000,
             "default_output_reserve_tokens" => 2_000,
             "supports_action_calls" => false,
             "route" => %{"adapter" => "local"}
           } =
             ProviderRegistry.profile("local-planner", %{
               "provider" => "local",
               "context_window" => 16_000,
               "output_reserve_tokens" => 2_000
             })
  end

  test "does not infer provider from model_id" do
    assert %{
             "schema_version" => "holt_provider_profile/v1",
             "model_id" => "local-planner",
             "status" => "rejected",
             "reason" => "missing_required:provider"
           } = profile = ProviderRegistry.profile("local-planner", %{})

    refute Map.has_key?(profile, "provider")
  end

  test "rejects string numeric limits" do
    assert %{
             "model_id" => "local-planner",
             "status" => "rejected",
             "reason" => "invalid_field:context_window"
           } =
             ProviderRegistry.profile("local-planner", %{
               "provider" => "local",
               "context_window" => "16000",
               "output_reserve_tokens" => "2000"
             })
  end

  test "rejects atom keyed attrs" do
    assert %{
             "model_id" => "local-planner",
             "status" => "rejected",
             "reason" => "invalid_attrs"
           } = profile = ProviderRegistry.profile("local-planner", %{provider: "local"})

    refute Map.has_key?(profile, "provider")
  end

  test "rejects invalid optional route fields" do
    assert %{
             "model_id" => "gpt-5.2",
             "status" => "rejected",
             "reason" => "invalid_field:api_key_env"
           } =
             ProviderRegistry.profile("gpt-5.2", %{
               "provider" => "openai",
               "api_key_env" => :openai_api_key
             })
  end

  test "keeps explicit openrouter route fields" do
    assert %{
             "route" => %{
               "adapter" => "openrouter",
               "api_key_env" => "OPENROUTER_API_KEY",
               "base_url" => "https://openrouter.ai/api/v1"
             }
           } =
             ProviderRegistry.profile("claude-sonnet-4.5", %{
               "provider" => "openrouter",
               "api_key_env" => "OPENROUTER_API_KEY",
               "base_url" => "https://openrouter.ai/api/v1"
             })
  end
end
