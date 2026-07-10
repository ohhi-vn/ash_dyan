defmodule AshDyan.DataLayer.Postgres do
  @moduledoc """
  Capability set for the `AshPostgres` data layer.

  All four v1 capabilities are supported:

  - `:frequency` / `:aggregate` — native Ash aggregates.
  - `:time_bucket` — `date_trunc`-style bucketing via a Postgres fragment.
  - `:percentile` — Postgres `percentile_cont` custom aggregate.
  """
  @behaviour AshDyan.DataLayer

  @impl true
  def supports?(_resource, _capability), do: true
end
