defmodule HoltWorks do
  @moduledoc """
  HoltWorks is the local-first corporate agent runtime.
  """

  def version do
    :holtworks
    |> Application.spec(:vsn)
    |> to_string()
  end
end
