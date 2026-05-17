defmodule Holt.Skills do
  @moduledoc """
  Markdown skill discovery and relevance selection.
  """

  alias Holt.{Clock, Paths, TextMatch}
  alias Holt.Tasks.RuntimeContracts

  def list(opts \\ []) do
    home = Paths.home(opts)
    root = Paths.workspace_root(opts)

    [Paths.global_skills_dir(home), Paths.workspace_skills_dir(root)]
    |> Enum.flat_map(&skill_files/1)
    |> Enum.map(&parse_file/1)
    |> Enum.reject(&is_nil/1)
  end

  def relevant(objective, opts \\ []) do
    objective_tokens = TextMatch.tokens(objective)

    opts
    |> list()
    |> Enum.map(fn skill -> {score(skill, objective_tokens), skill} end)
    |> Enum.filter(fn {score, _skill} -> score > 0 end)
    |> Enum.sort_by(fn {score, skill} -> {-score, skill.name} end)
    |> Enum.map(fn {_score, skill} -> skill end)
  end

  def search(params \\ %{}, opts \\ []) do
    query =
      params
      |> RuntimeContracts.string_keys()
      |> Map.get("query", "")
      |> to_string()
      |> String.downcase()

    opts
    |> list()
    |> Enum.filter(fn skill ->
      query == "" or
        String.contains?(String.downcase(skill.name), query) or
        String.contains?(String.downcase(skill.description), query) or
        String.contains?(String.downcase(Enum.join(skill.triggers, " ")), query)
    end)
    |> Enum.map(&skill_summary/1)
  end

  def load(params, opts \\ []) when is_map(params) do
    params = RuntimeContracts.string_keys(params)
    slug = text(params, "slug") || text(params, "name")

    opts
    |> list()
    |> Enum.find(&(skill_slug(&1.name) == skill_slug(slug) or &1.name == slug))
    |> case do
      nil -> {:error, :skill_not_found}
      skill -> {:ok, skill_payload(skill)}
    end
  end

  def save(params, opts \\ [])

  def save(params, opts) when is_map(params) do
    params = RuntimeContracts.string_keys(params)

    with {:ok, name} <- required_text(params, "name"),
         {:ok, description} <- required_text(params, "description"),
         {:ok, body} <- required_text(params, "body") do
      slug = skill_slug(text(params, "slug") || name)
      target = skill_path(slug, opts)

      if File.exists?(target) do
        {:error, :skill_already_exists}
      else
        write_skill_file(target, name, description, body, params)
        write_scripts(slug, params["scripts"], opts)
        load(%{"slug" => slug}, opts)
      end
    end
  end

  def save(_params, _opts), do: {:error, :invalid_skill}

  def update(params, opts \\ [])

  def update(params, opts) when is_map(params) do
    params = RuntimeContracts.string_keys(params)

    with {:ok, slug} <- required_text(params, "slug"),
         {:ok, current} <- load(%{"slug" => slug}, opts) do
      name = text(params, "name") || current["name"]
      description = text(params, "description") || current["description"]
      body = text(params, "body") || current["content"]
      target = skill_path(skill_slug(slug), opts)
      write_skill_file(target, name, description, body, params, current)
      write_scripts(skill_slug(slug), params["scripts"], opts)
      load(%{"slug" => slug}, opts)
    end
  end

  def update(_params, _opts), do: {:error, :invalid_skill}

  def run_script(params, opts \\ [])

  def run_script(params, opts) when is_map(params) do
    params = RuntimeContracts.string_keys(params)

    with {:ok, slug} <- required_any_text(params, ["skill_slug", "slug", "name"]),
         {:ok, script_name} <- required_any_text(params, ["script_name", "script", "path"]),
         {:ok, script_path} <- script_path(slug, script_name, opts) do
      run_script_file(script_path, params["args"] || [], opts)
    end
  end

  def run_script(_params, _opts), do: {:error, :invalid_skill_script}

  def parse_file(path) do
    with {:ok, body} <- File.read(path) do
      {meta, content} = parse_frontmatter(body)

      %{
        path: path,
        name: Map.get(meta, "name") || Path.basename(path, ".md"),
        description: Map.get(meta, "description") || "",
        triggers: Map.get(meta, "triggers") || [],
        risk: Map.get(meta, "risk") || "read",
        version: Map.get(meta, "version") || "1",
        scope: Map.get(meta, "scope") || "workspace",
        scripts: skill_scripts(path),
        content: String.trim(content)
      }
    else
      _ -> nil
    end
  end

  defp skill_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(Path.extname(&1) == ".md"))
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  defp skill_summary(skill) do
    %{
      "name" => skill.name,
      "slug" => skill_slug(skill.name),
      "description" => skill.description,
      "risk" => skill.risk,
      "scope" => skill.scope,
      "version" => skill.version,
      "triggers" => skill.triggers,
      "scripts" => skill.scripts,
      "path" => skill.path
    }
  end

  defp skill_payload(skill) do
    skill
    |> skill_summary()
    |> Map.put("content", skill.content)
    |> Map.put("body", skill.content)
  end

  defp parse_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [frontmatter, content] -> {parse_meta(frontmatter), content}
      _ -> {%{}, rest}
    end
  end

  defp parse_frontmatter(body), do: {%{}, body}

  defp parse_meta(frontmatter) do
    frontmatter
    |> String.split("\n")
    |> parse_meta_lines(%{}, nil)
  end

  defp write_skill_file(path, name, description, body, params, current \\ %{}) do
    File.mkdir_p!(Path.dirname(path))

    version =
      current
      |> Map.get("version", "0")
      |> increment_version()

    triggers =
      params
      |> Map.get("triggers", Map.get(current, "triggers", []))
      |> normalize_string_list()

    risk = text(params, "risk") || Map.get(current, "risk", "read")
    scope = text(params, "scope") || Map.get(current, "scope", "workspace")

    frontmatter =
      [
        "---",
        "name: #{name}",
        "description: #{description}",
        "risk: #{risk}",
        "scope: #{scope}",
        "version: #{version}",
        "updated_at: #{Clock.iso_now()}",
        "triggers:",
        Enum.map(triggers, &"  - #{&1}"),
        "---",
        "",
        String.trim(to_string(body)),
        ""
      ]
      |> List.flatten()
      |> Enum.join("\n")

    File.write!(path, frontmatter)
    :ok
  end

  defp write_scripts(_slug, scripts, _opts) when scripts in [nil, %{}, []], do: :ok

  defp write_scripts(slug, scripts, opts) when is_map(scripts) do
    scripts
    |> Enum.each(fn {name, content} ->
      with {:ok, target} <- script_path_for_write(slug, name, opts) do
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, to_string(content))
      end
    end)

    :ok
  end

  defp write_scripts(_slug, _scripts, _opts), do: :ok

  defp run_script_file(path, args, opts) do
    args =
      args
      |> List.wrap()
      |> Enum.map(&to_string/1)

    {command, command_args} = script_command(path, args)

    {output, exit_code} =
      System.cmd(command, command_args,
        cd: Paths.workspace_root(opts),
        stderr_to_stdout: true,
        env: [{"HOLTWORKS", "1"}]
      )

    {:ok,
     %{
       "script" => Path.relative_to(path, Paths.workspace_root(opts)),
       "exit_code" => exit_code,
       "output" => String.slice(output, 0, 20_000)
     }}
  rescue
    reason -> {:error, reason}
  end

  defp script_command(path, args) do
    cond do
      String.ends_with?(path, ".sh") -> {"bash", [path | args]}
      String.ends_with?(path, ".py") -> {"python3", [path | args]}
      String.ends_with?(path, ".js") -> {"node", [path | args]}
      true -> {path, args}
    end
  end

  defp skill_path(slug, opts) do
    opts
    |> Paths.workspace_root()
    |> Paths.workspace_skills_dir()
    |> Path.join("#{skill_slug(slug)}.md")
  end

  defp script_path(slug, script_name, opts) do
    root = skill_script_dir(slug, opts) |> Path.expand()
    target = script_name |> to_string() |> Path.expand(root)

    if under_root?(target, root) and File.regular?(target) do
      {:ok, target}
    else
      {:error, :skill_script_not_found}
    end
  end

  defp script_path_for_write(slug, script_name, opts) do
    root = skill_script_dir(slug, opts) |> Path.expand()
    target = script_name |> to_string() |> Path.expand(root)

    if under_root?(target, root) do
      {:ok, target}
    else
      {:error, :skill_script_outside_skill}
    end
  end

  defp skill_script_dir(slug, opts) do
    opts
    |> Paths.workspace_root()
    |> Paths.workspace_skills_dir()
    |> Path.join(skill_slug(slug))
    |> Path.join("scripts")
  end

  defp skill_scripts(skill_file_path) do
    slug = Path.basename(skill_file_path, ".md") |> skill_slug()
    base_dir = Path.dirname(skill_file_path)
    scripts_dir = Path.join([base_dir, slug, "scripts"])

    case File.ls(scripts_dir) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(scripts_dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, scripts_dir))
        |> Enum.sort()

      _missing ->
        []
    end
  end

  defp required_text(params, key) do
    case text(params, key) do
      nil -> {:error, "#{key}_required"}
      value -> {:ok, value}
    end
  end

  defp required_any_text(params, keys) do
    keys
    |> Enum.find_value(&text(params, &1))
    |> case do
      nil -> {:error, :required_skill_argument_missing}
      value -> {:ok, value}
    end
  end

  defp text(params, key) do
    case params[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp normalize_string_list(value) do
    value
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp increment_version(value) do
    case Integer.parse(to_string(value)) do
      {integer, _rest} -> Integer.to_string(integer + 1)
      :error -> "1"
    end
  end

  defp skill_slug(nil), do: "skill"

  defp skill_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.to_charlist()
    |> Enum.map(&slug_char/1)
    |> collapse_slug_chars([])
    |> Enum.reverse()
    |> to_string()
    |> String.trim("-")
    |> case do
      "" -> "skill"
      slug -> slug
    end
  end

  defp slug_char(char) when char in ?a..?z, do: char
  defp slug_char(char) when char in ?0..?9, do: char
  defp slug_char(_char), do: ?-

  defp collapse_slug_chars([], acc), do: acc
  defp collapse_slug_chars([?- | rest], []), do: collapse_slug_chars(rest, [])
  defp collapse_slug_chars([?- | rest], [?- | _tail] = acc), do: collapse_slug_chars(rest, acc)
  defp collapse_slug_chars([char | rest], acc), do: collapse_slug_chars(rest, [char | acc])

  defp under_root?(target, root) do
    root
    |> Path.split()
    |> :lists.prefix(Path.split(target))
  end

  defp parse_meta_lines([], meta, _current_key), do: meta

  defp parse_meta_lines([line | rest], meta, current_key) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        parse_meta_lines(rest, meta, current_key)

      true ->
        parse_meta_line(trimmed, rest, meta, current_key)
    end
  end

  defp parse_meta_line(<<"- ", value::binary>>, rest, meta, current_key)
       when not is_nil(current_key) do
    values = Map.get(meta, current_key, [])

    parse_meta_lines(
      rest,
      Map.put(meta, current_key, values ++ [String.trim(value)]),
      current_key
    )
  end

  defp parse_meta_line(line, rest, meta, current_key) do
    case :binary.split(line, ":") do
      [key, value] ->
        key = String.trim(key)
        value = String.trim(value)

        if value == "" do
          parse_meta_lines(rest, Map.put(meta, key, []), key)
        else
          parse_meta_lines(rest, Map.put(meta, key, value), key)
        end

      _ ->
        parse_meta_lines(rest, meta, current_key)
    end
  end

  defp score(skill, objective_tokens) do
    cond do
      TextMatch.phrase_in_tokens?(skill.name, objective_tokens) ->
        10

      Enum.any?(skill.triggers, &TextMatch.phrase_in_tokens?(&1, objective_tokens)) ->
        8

      skill
      |> relevance_text()
      |> TextMatch.overlap_count(objective_tokens)
      |> Kernel.>(0) ->
        3

      true ->
        0
    end
  end

  defp relevance_text(skill) do
    Enum.join([skill.name, skill.description, Enum.join(skill.triggers, " ")], " ")
  end
end
