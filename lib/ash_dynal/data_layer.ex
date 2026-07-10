defmodule AshDynal.DataLayer do
  @moduledoc """
  Behaviour describing what analysis capabilities a given Ash data layer supports.

  AshDynal ships with implementations for `AshPostgres` and `Ash.DataLayer.Simple`
  (ETS). Other data layers fall back to a default that supports only the
  universally-safe capabilities (`:frequency`, `:aggregate`) and rejects
  `:time_bucket`/`:percentile` with a clear error rather than silently wrong
  results.

  The capability check is surfaced explicitly via `AshDynal.supports?/2` so
  callers can discover data-layer limits before issuing a query.
  """

  @callback supports?(module(), AshDynal.capability()) :: boolean()

  @doc "Resolve the data-layer capability module for a resource."
  @spec for_resource(module()) :: module()
  def for_resource(resource) do
    case Ash.Resource.Info.data_layer(resource) do
      data_layer when data_layer in [AshPostgres.DataLayer, AshPostgres] ->
        AshDynal.DataLayer.Postgres

      data_layer when data_layer in [Ash.DataLayer.Simple, Ash.DataLayer.Ets] ->
        AshDynal.DataLayer.Simple

      _ ->
        AshDynal.DataLayer.Default
    end
  end

  @doc "Returns true if the resource's data layer supports the capability."
  @spec supports?(module(), AshDynal.capability()) :: boolean()
  def supports?(resource, capability) do
    for_resource(resource).supports?(resource, capability)
  end
end
