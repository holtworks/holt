defmodule Holt.Bridge.Stdio.Skills do
  @moduledoc """
  Skill stdio requests.
  """

  alias Holt.Bridge.Stdio.Response
  alias Holt.Skills
  alias Holt.Tasks

  def search(params, opts), do: Response.ok(Skills.search(params, opts))

  def list(opts) do
    skills =
      Enum.map(Skills.list(opts), &Map.take(&1, [:name, :description, :risk, :triggers, :path]))

    Response.ok(skills)
  end

  def load(params, opts) do
    case Skills.load(params, opts) do
      {:ok, skill} -> Response.ok(skill)
      {:error, reason} -> Response.error(reason)
    end
  end

  def save(params, opts), do: Response.action(Tasks.execute_action("save_skill", params, opts))

  def update(params, opts),
    do: Response.action(Tasks.execute_action("update_skill", params, opts))

  def run_script(params, opts) do
    Response.action(Tasks.execute_action("run_skill_script", params, opts))
  end
end
