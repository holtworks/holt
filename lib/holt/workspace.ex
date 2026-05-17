defmodule Holt.Workspace do
  @moduledoc """
  Creates and inspects `.holtworks` project workspaces.
  """

  alias Holt.Paths

  def init(root, opts \\ []) do
    Paths.ensure_workspace(root)

    created =
      []
      |> maybe_write(root, "HOLT.md", default_holt(), opts)
      |> maybe_write(root, "AGENTS.md", default_agents(), opts)
      |> maybe_write(root, "TOOLS.md", default_tools(), opts)

    %{
      root: root,
      dir: Paths.workspace_dir(root),
      created: Enum.reverse(created)
    }
  end

  def initialized?(root) do
    File.dir?(Paths.workspace_dir(root))
  end

  def read_instruction(root, filename) do
    path = Paths.workspace_file(root, filename)

    case File.read(path) do
      {:ok, body} -> String.trim(body)
      _ -> ""
    end
  end

  def default_holt do
    """
    # Holtworks

    Work carefully. Prefer small, reversible changes. Ask before writing files,
    running commands, or accessing network resources outside the configured
    workspace.
    """
  end

  def default_agents do
    """
    # Agents

    ## default

    General-purpose local agent for reading, writing, planning, and executing
    approved tasks in this workspace.
    """
  end

  def default_tools do
    """
    # Tools

    Allowed without approval:
    - list_files
    - read_file
    - search_files
    - search_memory
    - ask_user_question
    - list_skills
    - load_skill
    - list_agents
    - list_agent_cards
    - get_agent_card
    - list_agent_skills
    - get_repair_run

    Requires approval:
    - write_file
    - append_file
    - run_command
    - fetch_url
    - delegate_to_agent
    - set_page_title
    - create_page
    - write_to_document
    - save_skill
    - update_skill
    - run_skill_script
    - create_agent
    - update_agent
    - suspend_agent
    - resume_agent
    - delete_agent
    - invoke_agent
    - start_repair_run
    - record_repair_run_artifact
    - reconcile_repair_prediction
    - score_repair_predictions
    - choose_repair_strategy
    - draft_repair_architecture_plan
    - draft_repair_blast_radius
    - draft_repair_original_issue_check
    - execute_repair_original_issue_check
    - execute_repair_impact_check
    - draft_repair_related_issue_sweep
    - begin_repair_implementation
    - approve_repair_gate
    - complete_repair_run
    """
  end

  defp maybe_write(created, root, filename, content, opts) do
    path = Paths.workspace_file(root, filename)

    if opts[:force] || not File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      [filename | created]
    else
      created
    end
  end
end
