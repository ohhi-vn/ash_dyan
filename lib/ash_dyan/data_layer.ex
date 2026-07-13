defmodule AshDyan.DataLayer do
  @moduledoc """
  Behaviour describing what analysis capabilities a given Ash data layer supports.

  AshDyan ships with implementations for `AshPostgres` and `Ash.DataLayer.Simple`
  (ETS). Other data layers fall back to a default that supports only the
  universally-safe capabilities (`:frequency`, `:aggregate`) and rejects
  `:time_bucket`/`:percentile` with a clear error rather than silently wrong
  results.

  The capability check is surfaced explicitly via `AshDyan.supports?/2` so
  callers can discover data-layer limits before issuing a query.

  ## Extending with third-party data layers

  The mapping from an Ash data-layer module to its `AshDyan.DataLayer`
  capability implementation is config-mergeable, so a downstream app can register
  its own data layer without patching AshDyan:

      config :ash_dyan, :data_layer_capabilities, %{
        MyApp.CustomDataLayer => MyApp.AshDyan.CustomCapabilities
      }
  """

  alias Ash.Resource.Info

  @callback supports?(module(), AshDyan.capability()) :: boolean()

  @doc """
  Optional callback for SQL-pushdown of time bucketing.

  A data layer that can express a time bucket natively (e.g. Postgres
  `date_trunc`) implements this and returns `{:ok, query}`. The default returns
  `:not_supported`, in which case the engine falls back to in-memory bucketing.
  """
  @callback pushdown_time_bucket(Ash.Query.t(), atom(), AshDyan.time_bucket()) ::
              {:ok, Ash.Query.t()} | :not_supported
  @optional_callbacks [pushdown_time_bucket: 3]

  @builtin %{
    AshPostgres.DataLayer => AshDyan.DataLayer.Postgres,
    AshPostgres => AshDyan.DataLayer.Postgres,
    Ash.DataLayer.Simple => AshDyan.DataLayer.Simple,
    Ash.DataLayer.Ets => AshDyan.DataLayer.Simple
  }

  @doc """
  Resolve the data-layer capability module for a resource.

  Built-in mappings are merged with `config :ash_dyan, :data_layer_capabilities`,
  so third-party data layers can register their own capability module.
  """
  @spec for_resource(module()) :: module()
  def for_resource(resource) do
    data_layer = Info.data_layer(resource)
    registry = Map.merge(@builtin, Application.get_env(:ash_dyan, :data_layer_capabilities, %{}))
    Map.get(registry, data_layer, AshDyan.DataLayer.Default)
  end

  @doc """
  Returns true if the resource's data layer supports the capability.
  """
  @spec supports?(module(), AshDyan.capability()) :: boolean()
  def supports?(resource, capability) do
    for_resource(resource).supports?(resource, capability)
  end
end
