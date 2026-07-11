defmodule AshDyan.Domain.Info do
  @moduledoc """
  Introspection helpers for the domain-level `dyan` registry.
  """

  alias AshDyan.Dsl.Domain.AnalyzableResource
  alias Spark.Dsl.Extension

  @doc "Returns the list of registered analyzable resources for a domain."
  @spec analyzable_resources(module()) :: [module()]
  def analyzable_resources(domain) do
    domain
    |> Extension.get_entities([:dyan])
    |> Enum.map(fn %AnalyzableResource{resource: resource} -> resource end)
  end
end
