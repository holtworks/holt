defmodule HoltWorks.Runtime.Context do
  @moduledoc """
  Builds bounded local context from workspace instructions, skills, and memory.
  """

  alias HoltWorks.{Memory, Skills, Workspace}

  def build(objective, opts \\ []) do
    root = HoltWorks.Paths.workspace_root(opts)
    selected_skills = Skills.relevant(objective, opts)
    memories = Memory.search(objective, opts) |> Enum.take(10)

    %{
      objective: objective,
      workspace: root,
      holt: Workspace.read_instruction(root, "HOLT.md"),
      agents: Workspace.read_instruction(root, "AGENTS.md"),
      tools: Workspace.read_instruction(root, "TOOLS.md"),
      skills: selected_skills,
      memories: memories
    }
  end

  def prompt_section(context) do
    skills =
      context.skills
      |> Enum.map(fn skill -> "## #{skill.name}\n#{skill.content}" end)
      |> Enum.join("\n\n")

    memories =
      context.memories
      |> Enum.map(&("- " <> Map.get(&1, "text", "")))
      |> Enum.join("\n")

    """
    # Workspace Policy
    #{context.holt}

    # Agents
    #{context.agents}

    # Tools
    #{context.tools}

    # Relevant Skills
    #{skills}

    # Relevant Memory
    #{memories}
    """
  end
end
