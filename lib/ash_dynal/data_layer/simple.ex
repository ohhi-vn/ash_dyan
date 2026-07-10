defmodule AshDynal.DataLayer.Simple do
  @moduledoc """
  Capability set for the in-memory `Ash.DataLayer.Simple` (ETS) data layer.

  - `:frequency` and `:aggregate` are supported (computed in memory by the
    engine).
  - `:time_bucket` is supported via a manual in-memory bucketing fallback.
  - `:percentile` is **not** supported on ETS in v1 (no native percentile
    function); callers get a clear "unsupported" error.
  """
  @behaviour AshDynal.DataLayer

  @impl true
  def supports?(_resource, capability) when capability in [:frequency, :aggregate, :time_bucket],
    do: true

  def supports?(_resource, :percentile), do: false
end
