defmodule AshDyan.DataLayer.Postgres do
  @moduledoc """
  Capability set for the `AshPostgres` data layer.

  All five v1 capabilities are supported:

  - `:frequency` / `:aggregate` — native Ash aggregates.
  - `:time_bucket` — `date_trunc`-style bucketing via a Postgres fragment.
  - `:percentile` — Postgres `percentile_cont` custom aggregate.
  - `:histogram` — computed in memory from the returned rows.
  """
  @behaviour AshDyan.DataLayer

  @impl true
  def supports?(_resource, _capability), do: true
end
