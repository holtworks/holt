defmodule HoltWorks.Tasks.RuntimeContracts do
  @moduledoc false

  def string_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  def string_keys(_value), do: %{}

  def normalize_value(value) when is_map(value), do: string_keys(value)
  def normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  def normalize_value(value), do: value

  def normalize_map(value) when is_map(value), do: string_keys(value)
  def normalize_map(_value), do: %{}

  def value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  def value(_map, _key), do: nil

  def text(map, key, default \\ nil)

  def text(map, key, default) when is_map(map) do
    case value(map, key) do
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

  def text(_map, _key, default), do: default

  def normalize_string_list(nil), do: []

  def normalize_string_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.uniq()
  end

  def normalize_string_list(value) do
    text = value |> to_string() |> String.trim()

    if text == "" do
      []
    else
      text
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  def stable_id(prefix, parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "#{prefix}_#{digest}"
  end

  def truthy?(true), do: true
  def truthy?("true"), do: true
  def truthy?(1), do: true
  def truthy?("1"), do: true
  def truthy?(_value), do: false

  def number(value, _fallback) when is_integer(value), do: value * 1.0
  def number(value, _fallback) when is_float(value), do: value
  def number(_value, fallback), do: fallback

  def integer(value) when is_integer(value), do: value
  def integer(value) when is_float(value), do: trunc(value)
  def integer(value) when is_binary(value), do: parse_integer(value)
  def integer(_value), do: 0

  def reject_empty(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> 0
    end
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false
end
