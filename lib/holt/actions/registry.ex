defmodule Holt.Actions.Registry do
  @moduledoc """
  Action discovery boundary.

  The registry answers what Holt can do. It does not execute actions and it
  does not serialize provider-specific action schemas.
  """

  alias Holt.Actions

  def definitions(opts \\ []), do: Actions.definitions(opts)

  def get(name, opts \\ []), do: Actions.get(name, opts)

  def search(filters \\ %{}, opts \\ []), do: Actions.search(filters, opts)

  def catalog(context \\ %{}, opts \\ []), do: Actions.agent_action_catalog(context, opts)

  def provider_catalog(context \\ %{}, opts \\ []),
    do: Actions.provider_action_catalog(context, opts)

  def providers(context \\ %{}, opts \\ []), do: Actions.action_providers(context, opts)

  def provider_ids(context \\ %{}, opts \\ []), do: Actions.action_provider_ids(context, opts)

  def provider_metadata(context \\ %{}, opts \\ []),
    do: Actions.action_provider_metadata(context, opts)
end
