defmodule HoltWorks.Env do
  @moduledoc """
  Minimal `.env` loader for local provider keys.
  """

  alias HoltWorks.Paths

  def load(opts \\ []) do
    opts
    |> env_file()
    |> case do
      nil -> :ok
      path -> load_file(path)
    end
  end

  def load_file(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.each(&put_line/1)

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_key_from_stdin(env_name) do
    case IO.gets("") do
      :eof ->
        {:error, :no_stdin}

      nil ->
        {:error, :no_stdin}

      value ->
        value = String.trim(value)

        if value == "" do
          {:error, :empty_key}
        else
          System.put_env(env_name, value)
          :ok
        end
    end
  end

  defp env_file(opts) do
    cond do
      opts[:env_file] ->
        opts[:env_file]

      System.get_env("HOLTWORKS_ENV_FILE") not in [nil, ""] ->
        System.get_env("HOLTWORKS_ENV_FILE")

      File.exists?(Path.join(Paths.workspace_root(opts), ".env")) ->
        Path.join(Paths.workspace_root(opts), ".env")

      true ->
        nil
    end
  end

  defp put_line(line) do
    line = String.trim(line)

    case line do
      "" -> :ok
      <<"#", _comment::binary>> -> :ok
      _ -> put_assignment(line)
    end
  end

  defp put_assignment(line) do
    case line |> strip_export() |> :binary.split("=") do
      [key, value] ->
        put_env(String.trim(key), value |> String.trim() |> unquote_value())

      _ ->
        :ok
    end
  end

  defp strip_export(<<"export ", rest::binary>>), do: rest
  defp strip_export(line), do: line

  defp put_env("", _value), do: :ok

  defp put_env(key, value) do
    if System.get_env(key) in [nil, ""] do
      System.put_env(key, value)
    end
  end

  defp unquote_value(<<"\"", rest::binary>>), do: trim_closing_quote(rest, ?")
  defp unquote_value(<<"'", rest::binary>>), do: trim_closing_quote(rest, ?')
  defp unquote_value(value), do: value

  defp trim_closing_quote(value, quote) when byte_size(value) > 0 do
    body_size = byte_size(value) - 1

    case value do
      <<body::binary-size(body_size), ^quote>> -> body
      _ -> value
    end
  end

  defp trim_closing_quote(value, _quote), do: value
end
