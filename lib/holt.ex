defmodule Holt do
  @moduledoc """
  Holt helps teams turn local project context into completed work.
  """

  def version do
    :holt
    |> Application.spec(:vsn)
    |> to_string()
  end
end
