defmodule Holt.Tasks.Attributes do
  @moduledoc """
  Boundary normalization for task-facing attributes.

  This module keeps user/API input conversion explicit and reusable. Callers should
  normalize incoming maps once, then make workflow decisions from structured values.
  """

  alias Holt.Clock

  @estimates [nil, 1, 2, 3, 5, 8, 13]

  @link_types ~w(blocks depends_on causes relates_to duplicates clones implements tests fixes tracks)

  def required_text(attrs, key) do
    value =
      attrs
      |> Map.get(key)
      |> to_string()
      |> String.trim()

    if value == "" do
      {:error, {:missing_required, key}}
    else
      {:ok, value}
    end
  end

  def optional_text(attrs, key, default \\ nil) do
    value = Map.get(attrs, key, default)

    case value do
      nil ->
        default

      _ ->
        text = value |> to_string() |> String.trim()
        if text == "", do: default, else: text
    end
  end

  def enum_value(attrs, key, allowed, default) do
    value = optional_text(attrs, key, default)

    cond do
      value in allowed -> {:ok, value}
      value in [nil, ""] -> {:error, {:missing_required, key}}
      true -> {:error, {:invalid_value, key, value, allowed}}
    end
  end

  def estimate_value(nil), do: {:ok, nil}
  def estimate_value(""), do: {:ok, nil}

  def estimate_value(value) when is_integer(value) do
    if value in @estimates do
      {:ok, value}
    else
      {:error, {:invalid_value, "estimate", value, @estimates}}
    end
  end

  def estimate_value(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> estimate_value(number)
      _ -> {:error, {:invalid_value, "estimate", value, @estimates}}
    end
  end

  def normalize_string_list(nil), do: []

  def normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  def normalize_string_list(value) do
    text = value |> to_string() |> String.trim()
    if text == "", do: [], else: [text]
  end

  def normalize_labels(nil), do: []

  def normalize_labels(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_labels/1)
    |> Enum.reduce([], fn label, acc ->
      if label_exists?(acc, label["name"]), do: acc, else: acc ++ [label]
    end)
  end

  def normalize_labels(%{} = label) do
    if canonical_map?(label) do
      name = optional_text(label, "name")

      if name in [nil, ""] do
        []
      else
        [%{"name" => name, "color" => optional_text(label, "color", "#2563eb")}]
      end
    else
      []
    end
  end

  def normalize_labels(value) do
    value
    |> normalize_string_list()
    |> Enum.map(&%{"name" => &1, "color" => "#2563eb"})
  end

  def normalize_label_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def normalize_links(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_link/1)
    |> Enum.uniq_by(&{&1["target_id"], &1["type"]})
  end

  def normalize_links(_value), do: []

  def dependency_links(attrs) do
    attrs
    |> Map.get("depends_on_task_ids", [])
    |> normalize_string_list()
    |> Enum.map(fn target_id ->
      %{
        "id" => Clock.id("link"),
        "target_id" => target_id,
        "type" => "depends_on"
      }
    end)
  end

  def normalize_assignees(nil), do: []

  def normalize_assignees(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_assignees/1)
    |> Enum.reduce([], fn assignee, acc ->
      id = assignee_id(assignee)

      if missing_or_duplicate_assignee?(id, acc) do
        acc
      else
        acc ++ [assignee]
      end
    end)
  end

  def normalize_assignees(%{} = assignee) do
    if canonical_map?(assignee) do
      id = optional_text(assignee, "agent_id")

      if id in [nil, ""] do
        []
      else
        [
          %{
            "id" => id,
            "agent_id" => id,
            "kind" => optional_text(assignee, "kind", "agent"),
            "display_name" => optional_text(assignee, "display_name", id),
            "avatar_url" => optional_text(assignee, "avatar_url"),
            "agent_ref" => optional_text(assignee, "agent_ref"),
            "agent_handle" => optional_text(assignee, "agent_handle"),
            "work_role" => optional_text(assignee, "work_role", "worker")
          }
          |> reject_empty()
        ]
      end
    else
      []
    end
  end

  def normalize_assignees(value) do
    value
    |> normalize_string_list()
    |> Enum.map(fn id ->
      %{
        "id" => id,
        "agent_id" => id,
        "kind" => "agent",
        "display_name" => id,
        "work_role" => "worker"
      }
    end)
  end

  defp missing_or_duplicate_assignee?(id, assignees) do
    Enum.any?([id in [nil, ""], Enum.any?(assignees, &(assignee_id(&1) == id))], & &1)
  end

  def normalize_recurrence(nil), do: nil
  def normalize_recurrence(""), do: nil

  def normalize_recurrence(%{} = recurrence) do
    if canonical_map?(recurrence) do
      frequency = optional_text(recurrence, "frequency")

      if frequency in ["daily", "weekly", "monthly"] do
        %{
          "frequency" => frequency,
          "interval" => recurrence_interval(Map.get(recurrence, "interval")),
          "timezone" => optional_text(recurrence, "timezone"),
          "ends_at" => optional_text(recurrence, "ends_at")
        }
        |> reject_empty()
      else
        nil
      end
    else
      nil
    end
  end

  def normalize_recurrence(_value), do: nil

  def normalize_metadata(%{} = metadata) do
    if canonical_map?(metadata), do: metadata, else: %{}
  end

  def normalize_metadata(_metadata), do: %{}

  def normalize_agent_policy(%{} = policy) do
    if canonical_map?(policy) do
      policy
      |> Map.take([
        "auto_continue",
        "continuation_allowed",
        "max_continuation_depth",
        "retry_on_failure",
        "source"
      ])
      |> reject_empty()
    else
      %{}
    end
  end

  def normalize_agent_policy(_policy), do: %{}

  def positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  def positive_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
  end

  def truthy?(value), do: value in [true, "true", "1", 1, nil]

  def canonical_map?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and canonical_value?(value) end)
  end

  def canonical_map?(_value), do: false

  def reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp normalize_link(%{} = link) do
    if canonical_map?(link) do
      type = optional_text(link, "type", "relates_to")
      target_id = optional_text(link, "target_id")

      cond do
        type not in @link_types ->
          []

        target_id in [nil, ""] ->
          []

        true ->
          [
            %{
              "id" => optional_text(link, "id", Clock.id("link")),
              "target_id" => target_id,
              "target_ref" => optional_text(link, "target_ref"),
              "type" => type
            }
            |> reject_empty()
          ]
      end
    else
      []
    end
  end

  defp normalize_link(_value), do: []

  defp label_exists?(labels, name) do
    normalized = normalize_label_name(name)
    Enum.any?(labels, &(normalize_label_name(&1["name"]) == normalized))
  end

  defp canonical_value?(value) when is_map(value), do: canonical_map?(value)
  defp canonical_value?(value) when is_list(value), do: Enum.all?(value, &canonical_value?/1)
  defp canonical_value?(_value), do: true

  defp assignee_id(%{} = assignee), do: assignee["agent_id"]
  defp assignee_id(_assignee), do: nil

  defp recurrence_interval(nil), do: 1

  defp recurrence_interval(value) when is_integer(value) and value > 0, do: value

  defp recurrence_interval(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end
end
