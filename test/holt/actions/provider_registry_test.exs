defmodule Holt.Actions.ProviderRegistryTest do
  use ExUnit.Case

  alias Holt.Actions.ProviderRegistry

  setup do
    ProviderRegistry.init()
    :ok
  end

  test "filters providers from canonical context only" do
    assert [%{"id" => "workspace"}] =
             ProviderRegistry.for_context(%{"action_provider_ids" => ["workspace"]})

    assert ProviderRegistry.for_context(%{action_provider_ids: ["workspace"]}) ==
             {:error, :invalid_provider_context}

    assert ProviderRegistry.for_context(%{"providers" => ["workspace"]}) ==
             {:error, {:obsolete_provider_context_key, "providers", "action_provider_ids"}}

    assert ProviderRegistry.for_context(%{"action_provider_ids" => "workspace"}) ==
             {:error, {:invalid_provider_context_field, "action_provider_ids"}}
  end

  test "metadata omits unregistered provider definitions" do
    definitions = [
      %{"name" => "read", "provider" => "workspace"},
      %{"name" => "ghost_action", "provider" => "ghost"}
    ]

    assert [
             %{
               "id" => "workspace",
               "name" => "Workspace",
               "actions" => ["read"],
               "action_count" => 1
             }
           ] = ProviderRegistry.metadata(definitions, %{"action_provider_ids" => ["workspace"]})

    refute ProviderRegistry.provider_name("ghost")
    refute ProviderRegistry.provider_description("ghost")
  end

  test "registration and lookup reject obsolete provider shapes" do
    assert ProviderRegistry.register(%{id: "custom", name: "Custom", description: "Provider"}) ==
             {:error, :invalid_provider}

    assert ProviderRegistry.get(:workspace) == {:error, :invalid_provider_id}
    assert ProviderRegistry.unregister(:workspace) == {:error, :invalid_provider_id}
  end
end
