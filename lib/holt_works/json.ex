defmodule HoltWorks.JSON do
  @moduledoc false

  def read(path, default \\ %{}) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
    else
      _ -> default
    end
  end

  def write(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
    :ok
  end

  def append_jsonl(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Jason.encode_to_iodata!(data), "\n"], [:append])
    :ok
  end

  def read_jsonl(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, value} -> [value]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end
end
