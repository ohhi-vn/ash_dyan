defmodule AshDynal.Dsl.Domain.Extension do
  @moduledoc """
  The `AshDynal` Spark DSL extension for domains.

  Adds a `dynal do ... end` section to a domain declaring a registry of
  analyzable resources for discovery. Cross-resource joins are explicitly out of
  scope for v1.

  ## Example

      defmodule MyApp.Shop do
        use Ash.Domain, extensions: [AshDynal.Domain]

        dynal do
          analyzable_resource MyApp.Order
          analyzable_resource MyApp.Invoice
        end
      end
  """

  @doc false
  def analyzable_resource_entity do
    %Spark.Dsl.Entity{
      name: :analyzable_resource,
      target: AshDynal.Dsl.Domain.AnalyzableResource,
      describe: "Registers a resource as analyzable within this domain.",
      args: [:resource],
      schema: [
        resource: [
          type: :atom,
          required: true,
          doc: "The resource module to register as analyzable."
        ]
      ]
    }
  end

  @dynal %Spark.Dsl.Section{
    name: :dynal,
    describe: """
    Declares which resources in this domain are analyzable, for discovery.

    This is a thin registry. Cross-resource joins are out of scope for v1.
    """,
    entities: [
      analyzable_resource_entity()
    ],
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@dynal],
    verifiers: [AshDynal.Dsl.Domain.Verifiers.ValidateAnalyzableResources]
end
