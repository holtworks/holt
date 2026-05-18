defmodule Holt.Boot do
  @moduledoc false

  use GenServer

  alias Holt.Actions.ProviderRegistry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ProviderRegistry.init()
    {:ok, %{booted?: true}}
  end
end
