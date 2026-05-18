defmodule Holt.Clock do
  @moduledoc false

  def now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
  end

  def iso_now do
    now()
    |> DateTime.to_iso8601()
  end

  def id(prefix) do
    random =
      12
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    "#{prefix}_#{random}"
  end

  def timestamp_slug do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%S%f")
  end
end
