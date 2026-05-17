defmodule HoltWorks.Agents do
  @moduledoc """
  Workspace-local agent profile and card registry.

  HoltWorks keeps this intentionally file-backed: agents are durable local
  teammates with lifecycle state, roles, skills, model/provider hints, and a
  compact card shape that task dispatch can consume.
  """

  alias HoltWorks.{Clock, JSON, Paths}

  @schema_version "holtworks_agent_profile/v1"
  @card_schema_version "holtworks_agent_card/v1"
  @event_schema_version "holtworks_agent_event/v1"
  @statuses ~w(active suspended archived)
  @work_roles ~w(worker verifier reviewer planner observer)
  @default_agent_id "default"

  def ensure_store(root) do
    Paths.ensure_workspace(root)
    unless File.exists?(path(root)), do: JSON.write(path(root), [])
    :ok
  end

  def path(root), do: Paths.workspace_file(root, "agents.json")
  def events_path(root), do: Paths.workspace_file(root, "agent_events.jsonl")

  def statuses, do: @statuses
  def work_roles, do: @work_roles

  def list(opts \\ []) do
    opts
    |> Paths.workspace_root()
    |> list_for_root()
  end

  def list_for_root(root) do
    ensure_store(root)

    [default_profile()] ++
      (root
       |> path()
       |> JSON.read([])
       |> Enum.filter(&is_map/1)
       |> Enum.map(&normalize_profile/1)
       |> Enum.reject(&(&1["id"] == @default_agent_id)))
  end

  def create(root, attrs) when is_map(attrs) do
    ensure_store(root)
    attrs = string_keys(attrs)

    with {:ok, id} <- profile_id(attrs),
         :ok <- ensure_new_id(root, id),
         {:ok, profile} <- build_profile(attrs, id, Clock.iso_now()) do
      records = stored_profiles(root) ++ [profile]
      JSON.write(path(root), records)
      append_event(root, profile, "agent.created", %{"fields" => Map.keys(attrs)})
      {:ok, profile}
    end
  end

  def create(_root, _attrs), do: {:error, :invalid_agent_attrs}

  def update(root, id, attrs) when is_binary(id) and id != "" and is_map(attrs) do
    attrs = string_keys(attrs)

    with {:ok, current} <- get_stored(root, id),
         {:ok, patch} <- profile_patch(attrs),
         profile <- current |> Map.merge(patch) |> Map.put("updated_at", Clock.iso_now()) do
      upsert(root, profile)
      append_event(root, profile, "agent.updated", %{"fields" => Map.keys(patch)})
      {:ok, profile}
    end
  end

  def update(_root, _id, _attrs), do: {:error, :invalid_agent_attrs}

  def suspend(root, id, attrs \\ %{}) when is_binary(id) and id != "" do
    lifecycle_transition(root, id, "suspended", attrs, "agent.suspended")
  end

  def resume(root, id, attrs \\ %{}) when is_binary(id) and id != "" do
    lifecycle_transition(root, id, "active", attrs, "agent.resumed")
  end

  def archive(root, id, attrs \\ %{}) when is_binary(id) and id != "" do
    lifecycle_transition(root, id, "archived", attrs, "agent.archived")
  end

  def delete(root, id, attrs \\ %{})

  def delete(root, id, attrs) when is_binary(id) and id != "" do
    attrs = string_keys(attrs || %{})

    with :ok <- ensure_deletable_id(id),
         {:ok, profile} <- get_stored(root, id) do
      deleted =
        profile
        |> Map.put("status", "deleted")
        |> Map.put("lifecycle_state", "deleted")
        |> Map.put("deleted_at", Clock.iso_now())
        |> Map.put("deletion_reason", optional_text(attrs, "reason"))
        |> reject_empty()

      profiles = Enum.reject(stored_profiles(root), &(&1["id"] == profile["id"]))
      JSON.write(path(root), profiles)
      append_event(root, deleted, "agent.deleted", %{"reason" => optional_text(attrs, "reason")})

      {:ok, deleted}
    end
  end

  def delete(_root, _id, _attrs), do: {:error, :invalid_agent_id}

  def get(root, id) when is_binary(id) and id != "" do
    root
    |> list_for_root()
    |> Enum.find(&profile_matches?(&1, id))
    |> case do
      nil -> {:error, :agent_not_found}
      profile -> {:ok, profile}
    end
  end

  def get(_root, _id), do: {:error, :invalid_agent_id}

  def card(root, id) do
    with {:ok, profile} <- get(root, id) do
      {:ok, profile_card(profile)}
    end
  end

  def list_cards(root, opts \\ []) do
    status = option(opts, :status)

    root
    |> list_for_root()
    |> filter_status(status)
    |> Enum.map(&profile_card/1)
  end

  def list_skills(root, id) do
    with {:ok, profile} <- get(root, id) do
      {:ok, profile["skills"] || []}
    end
  end

  def enrich_assignees(root, assignees) when is_list(assignees) do
    Enum.map(assignees, &enrich_assignee(root, &1))
  end

  def enrich_assignees(_root, _assignees), do: []

  def dispatchable_assignees(root, assignees) do
    root
    |> enrich_assignees(assignees)
    |> Enum.filter(&dispatchable_assignee?/1)
  end

  def assignees_for_ids(root, ids) when is_list(ids) do
    Enum.map(ids, fn id ->
      case get(root, id) do
        {:ok, profile} -> profile_assignee(profile)
        {:error, _reason} -> ad_hoc_assignee(id)
      end
    end)
  end

  def profile_card(profile) when is_map(profile) do
    %{
      "schema_version" => @card_schema_version,
      "id" => profile["id"],
      "agent_id" => profile["id"],
      "display_name" => profile["display_name"],
      "agent_handle" => profile["agent_handle"],
      "agent_ref" => profile["agent_ref"],
      "status" => profile["status"],
      "lifecycle_state" => profile["lifecycle_state"],
      "work_roles" => profile["work_roles"],
      "default_work_role" => profile["default_work_role"],
      "skills" => profile["skills"],
      "model" => profile["model"],
      "provider" => profile["provider"],
      "description" => profile["description"],
      "capabilities" => profile["capabilities"],
      "permissions" => profile["permissions"]
    }
    |> reject_empty()
  end

  def profile_assignee(profile) when is_map(profile) do
    %{
      "id" => profile["id"],
      "kind" => "agent",
      "display_name" => profile["display_name"] || profile["id"],
      "agent_ref" => profile["agent_ref"],
      "agent_handle" => profile["agent_handle"],
      "work_role" => profile["default_work_role"] || "worker",
      "work_roles" => profile["work_roles"] || ["worker"],
      "status" => profile["status"],
      "lifecycle_state" => profile["lifecycle_state"],
      "skills" => profile["skills"],
      "model" => profile["model"],
      "provider" => profile["provider"],
      "agent_card" => profile_card(profile)
    }
    |> reject_empty()
  end

  defp build_profile(attrs, id, now) do
    with {:ok, status} <- enum_value(attrs, "status", @statuses, "active") do
      profile =
        %{
          "schema_version" => @schema_version,
          "id" => id,
          "display_name" =>
            optional_text(attrs, "display_name") ||
              optional_text(attrs, "name") ||
              optional_text(attrs, "title") ||
              id,
          "description" => optional_text(attrs, "description"),
          "agent_handle" =>
            normalize_handle(
              optional_text(attrs, "agent_handle") || optional_text(attrs, "handle")
            ),
          "agent_ref" => optional_text(attrs, "agent_ref") || optional_text(attrs, "ref"),
          "status" => status,
          "lifecycle_state" => status,
          "work_roles" =>
            normalize_work_roles(attrs["work_roles"] || attrs["work_role"] || attrs["role"]),
          "default_work_role" => default_work_role(attrs),
          "skills" => normalize_skills(attrs["skills"] || attrs["skill"]),
          "model" => optional_text(attrs, "model"),
          "provider" => optional_text(attrs, "provider"),
          "instructions" =>
            optional_text(attrs, "instructions") || optional_text(attrs, "system_prompt"),
          "capabilities" => normalize_string_list(attrs["capabilities"] || attrs["capability"]),
          "permissions" => normalize_permissions(attrs["permissions"]),
          "metadata" => normalize_metadata(attrs["metadata"]),
          "created_at" => now,
          "updated_at" => now
        }
        |> ensure_default_role()
        |> reject_empty()

      {:ok, profile}
    end
  end

  defp profile_patch(attrs) do
    patch =
      %{}
      |> maybe_put(
        "display_name",
        optional_text(attrs, "display_name") || optional_text(attrs, "name") ||
          optional_text(attrs, "title")
      )
      |> maybe_put("description", optional_text(attrs, "description"))
      |> maybe_put(
        "agent_handle",
        normalize_handle(optional_text(attrs, "agent_handle") || optional_text(attrs, "handle"))
      )
      |> maybe_put("agent_ref", optional_text(attrs, "agent_ref") || optional_text(attrs, "ref"))
      |> maybe_put("work_roles", maybe_work_roles(attrs))
      |> maybe_put("default_work_role", maybe_default_work_role(attrs))
      |> maybe_put("skills", maybe_skills(attrs))
      |> maybe_put("model", optional_text(attrs, "model"))
      |> maybe_put("provider", optional_text(attrs, "provider"))
      |> maybe_put(
        "instructions",
        optional_text(attrs, "instructions") || optional_text(attrs, "system_prompt")
      )
      |> maybe_put("capabilities", maybe_string_list(attrs, "capabilities", "capability"))
      |> maybe_put("permissions", maybe_permissions(attrs))
      |> maybe_put("metadata", maybe_metadata(attrs))

    status = optional_text(attrs, "status")

    cond do
      status in [nil, ""] ->
        {:ok, patch}

      status in @statuses ->
        {:ok, patch |> Map.put("status", status) |> Map.put("lifecycle_state", status)}

      true ->
        {:error, {:invalid_enum, "status", @statuses}}
    end
  end

  defp lifecycle_transition(_root, @default_agent_id, _status, _attrs, _event_kind),
    do: {:error, :default_agent_is_builtin}

  defp lifecycle_transition(root, id, status, attrs, event_kind) do
    attrs = string_keys(attrs || %{})

    with {:ok, profile} <- get_stored(root, id) do
      now = Clock.iso_now()

      profile =
        profile
        |> Map.put("status", status)
        |> Map.put("lifecycle_state", status)
        |> Map.put("lifecycle_reason", optional_text(attrs, "reason"))
        |> Map.put("updated_at", now)
        |> reject_empty()

      upsert(root, profile)
      append_event(root, profile, event_kind, %{"reason" => optional_text(attrs, "reason")})
      {:ok, profile}
    end
  end

  defp ensure_deletable_id(@default_agent_id), do: {:error, :default_agent_is_builtin}
  defp ensure_deletable_id(_id), do: :ok

  defp get_stored(root, id) do
    root
    |> stored_profiles()
    |> Enum.find(&profile_matches?(&1, id))
    |> case do
      nil -> {:error, :agent_not_found}
      profile -> {:ok, profile}
    end
  end

  defp stored_profiles(root) do
    ensure_store(root)

    root
    |> path()
    |> JSON.read([])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_profile/1)
  end

  defp upsert(root, profile) do
    profiles = stored_profiles(root)

    profiles =
      if Enum.any?(profiles, &(&1["id"] == profile["id"])) do
        Enum.map(profiles, fn current ->
          if current["id"] == profile["id"], do: profile, else: current
        end)
      else
        profiles ++ [profile]
      end

    JSON.write(path(root), profiles)
    :ok
  end

  defp append_event(root, profile, kind, metadata) do
    event =
      %{
        "schema_version" => @event_schema_version,
        "id" => Clock.id("agent_event"),
        "kind" => kind,
        "type" => kind,
        "agent_id" => profile["id"],
        "status" => profile["status"],
        "lifecycle_state" => profile["lifecycle_state"],
        "metadata" => metadata,
        "at" => Clock.iso_now()
      }
      |> reject_empty()

    JSON.append_jsonl(events_path(root), event)
    event
  end

  defp ensure_new_id(root, id) do
    case get(root, id) do
      {:ok, _profile} -> {:error, :agent_already_exists}
      {:error, :agent_not_found} -> :ok
      error -> error
    end
  end

  defp profile_id(attrs) do
    id =
      optional_text(attrs, "id") ||
        optional_text(attrs, "agent_id") ||
        optional_text(attrs, "handle") ||
        Clock.id("agent")

    if id in [nil, ""], do: {:error, :invalid_agent_id}, else: {:ok, normalize_id(id)}
  end

  defp normalize_profile(profile) do
    profile
    |> string_keys()
    |> Map.put_new("schema_version", @schema_version)
    |> Map.put_new("status", "active")
    |> Map.put_new("lifecycle_state", "active")
    |> Map.update("work_roles", ["worker"], &normalize_work_roles/1)
    |> Map.update("skills", [], &normalize_skills/1)
    |> ensure_default_role()
    |> reject_empty()
  end

  defp default_profile do
    now = Clock.iso_now()

    %{
      "schema_version" => @schema_version,
      "id" => @default_agent_id,
      "display_name" => "Default",
      "status" => "active",
      "lifecycle_state" => "active",
      "work_roles" => ["worker"],
      "default_work_role" => "worker",
      "skills" => [
        %{
          "id" => "local_task_work",
          "name" => "Local task work",
          "description" => "Runs local HoltWorks task objectives."
        }
      ],
      "created_at" => now,
      "updated_at" => now,
      "builtin" => true
    }
  end

  defp enrich_assignee(root, assignee) when is_map(assignee) do
    assignee = string_keys(assignee)
    id = assignee["id"] || assignee["agent_id"]

    case get(root, id || "") do
      {:ok, profile} ->
        assignee
        |> Map.merge(profile_assignee(profile))
        |> Map.put("status", profile["status"])
        |> Map.put("lifecycle_state", profile["lifecycle_state"])
        |> Map.put("agent_card", profile_card(profile))
        |> reject_empty()

      {:error, _reason} ->
        assignee
    end
  end

  defp enrich_assignee(_root, assignee), do: assignee

  defp dispatchable_assignee?(%{"status" => "active", "lifecycle_state" => "active"}), do: true
  defp dispatchable_assignee?(%{"status" => "active"}), do: true
  defp dispatchable_assignee?(%{"lifecycle_state" => "active"}), do: true

  defp dispatchable_assignee?(assignee) do
    assignee["status"] in [nil, ""] and assignee["lifecycle_state"] in [nil, ""]
  end

  defp ad_hoc_assignee(id) do
    %{
      "id" => id,
      "kind" => "agent",
      "display_name" => id,
      "work_role" => "worker",
      "status" => "active",
      "lifecycle_state" => "active"
    }
  end

  defp profile_matches?(profile, id) do
    profile["id"] == id or profile["agent_ref"] == id or profile["agent_handle"] == id or
      profile["agent_handle"] == normalize_handle(id)
  end

  defp filter_status(profiles, nil), do: profiles
  defp filter_status(profiles, ""), do: profiles
  defp filter_status(profiles, status), do: Enum.filter(profiles, &(&1["status"] == status))

  defp enum_value(attrs, key, allowed, default) do
    value = optional_text(attrs, key, default)

    if value in allowed do
      {:ok, value}
    else
      {:error, {:invalid_enum, key, allowed}}
    end
  end

  defp default_work_role(attrs) do
    role =
      optional_text(attrs, "default_work_role") || optional_text(attrs, "work_role") ||
        optional_text(attrs, "role")

    if role in @work_roles, do: role, else: "worker"
  end

  defp maybe_default_work_role(attrs) do
    role =
      optional_text(attrs, "default_work_role") || optional_text(attrs, "work_role") ||
        optional_text(attrs, "role")

    if role in @work_roles, do: role, else: nil
  end

  defp ensure_default_role(profile) do
    roles = normalize_work_roles(profile["work_roles"])
    default_role = profile["default_work_role"]
    default_role = if default_role in roles, do: default_role, else: List.first(roles) || "worker"

    profile
    |> Map.put("work_roles", roles)
    |> Map.put("default_work_role", default_role)
  end

  defp maybe_work_roles(attrs) do
    if Map.has_key?(attrs, "work_roles") or Map.has_key?(attrs, "work_role") or
         Map.has_key?(attrs, "role") do
      normalize_work_roles(attrs["work_roles"] || attrs["work_role"] || attrs["role"])
    else
      nil
    end
  end

  defp normalize_work_roles(value) do
    roles =
      value
      |> normalize_string_list()
      |> Enum.filter(&(&1 in @work_roles))

    if roles == [], do: ["worker"], else: roles
  end

  defp maybe_skills(attrs) do
    if Map.has_key?(attrs, "skills") or Map.has_key?(attrs, "skill") do
      normalize_skills(attrs["skills"] || attrs["skill"])
    else
      nil
    end
  end

  defp normalize_skills(nil), do: []

  defp normalize_skills(skills) when is_list(skills) do
    skills
    |> Enum.flat_map(&normalize_skill/1)
    |> dedupe_by("id")
  end

  defp normalize_skills(skill), do: normalize_skills([skill])

  defp normalize_skill(%{} = skill) do
    skill = string_keys(skill)
    name = optional_text(skill, "name") || optional_text(skill, "id")

    if name in [nil, ""] do
      []
    else
      [
        %{
          "id" => normalize_id(optional_text(skill, "id", name)),
          "name" => name,
          "description" => optional_text(skill, "description"),
          "tool_names" => normalize_string_list(skill["tool_names"] || skill["tools"])
        }
        |> reject_empty()
      ]
    end
  end

  defp normalize_skill(skill) do
    name = optional_text(%{"value" => skill}, "value")

    if name in [nil, ""] do
      []
    else
      [%{"id" => normalize_id(name), "name" => name}]
    end
  end

  defp normalize_permissions(%{} = permissions), do: string_keys(permissions)
  defp normalize_permissions(_permissions), do: %{}

  defp maybe_permissions(attrs) do
    if Map.has_key?(attrs, "permissions"),
      do: normalize_permissions(attrs["permissions"]),
      else: nil
  end

  defp normalize_metadata(%{} = metadata), do: string_keys(metadata)
  defp normalize_metadata(_metadata), do: %{}

  defp maybe_metadata(attrs) do
    if Map.has_key?(attrs, "metadata"), do: normalize_metadata(attrs["metadata"]), else: nil
  end

  defp maybe_string_list(attrs, plural_key, singular_key) do
    if Map.has_key?(attrs, plural_key) or Map.has_key?(attrs, singular_key) do
      normalize_string_list(attrs[plural_key] || attrs[singular_key])
    else
      nil
    end
  end

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp dedupe_by(items, key) do
    items
    |> Enum.reduce({MapSet.new(), []}, fn item, {seen, acc} ->
      value = item[key]

      if value in [nil, ""] or MapSet.member?(seen, value) do
        {seen, acc}
      else
        {MapSet.put(seen, value), acc ++ [item]}
      end
    end)
    |> elem(1)
  end

  defp optional_text(map, key, default \\ nil)

  defp optional_text(map, key, default) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      nil ->
        default

      value ->
        value
        |> to_string()
        |> String.trim()
        |> case do
          "" -> default
          text -> text
        end
    end
  end

  defp optional_text(_map, _key, default), do: default

  defp normalize_handle(nil), do: nil
  defp normalize_handle(""), do: nil
  defp normalize_handle(<<"@", _rest::binary>> = handle), do: handle
  defp normalize_handle(handle), do: "@" <> handle

  defp normalize_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "_")
  end

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp string_keys(value), do: value

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp option(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp option(_opts, _key), do: nil

  defp maybe_put(map, _key, value) when value in [nil, "", [], %{}], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
