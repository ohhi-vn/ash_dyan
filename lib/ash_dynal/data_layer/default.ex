defmodule AshDynal.DataLayer.Default do
  @moduledoc """
  Default capability set for unknown data layers.

  Only the universally-safe capabilities (`:frequency`, `:aggregate`) are
  supported. `:time_bucket` and `:percentile` are rejected so callers get a
  clear "unsupported" error rather than silently wrong results.
  """
  @behaviour AshDynal.DataLayer

  @impl true
  def supports?(_resource, capability) when capability in [:frequency, :aggregate], do: true
  def supports?(_resource, _capability), do: false
end
