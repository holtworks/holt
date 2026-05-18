defmodule Holt.Runtime.Context do
  @moduledoc """
  Builds bounded local discovery context from agent instructions.
  """

  alias Holt.Workspace

  def build(objective, opts \\ []) do
    root = Holt.Paths.workspace_root(opts)
    agents = agent_instructions(opts, root)

    %{
      objective: objective,
      workspace: root,
      agent_instruction_file: Workspace.agent_instruction_file(),
      agents: agents,
      skills: [],
      memories: []
    }
  end

  def prompt_section(context) do
    """
    # Agent Instructions
    File: #{context.agent_instruction_file}
    #{context.agents}
    """
  end

  defp agent_instructions(opts, root) do
    case Keyword.get(opts, :agent_instructions) do
      instructions when is_binary(instructions) -> instructions
      _missing -> Workspace.read_agent_instructions(root)
    end
  end
end
