defmodule AshDyan.Domain do
  @moduledoc """
  The `AshDyan` Spark DSL extension for domains.

  Adds a `dynal do ... end` section to a domain declaring a registry of
  analyzable resources for discovery. Cross-resource joins are explicitly out of
  scope for v1.

  Use it in a domain:

      use Ash.Domain, extensions: [AshDyan.Domain]

  ## Example

      defmodule MyApp.Shop do
        use Ash.Domain, extensions: [AshDyan.Domain]

        dynal do
          analyzable_resource MyApp.Order
          analyzable_resource MyApp.Invoice
        end
      end
  """

  @analyzable_resource_entity %Spark.Dsl.Entity{
    name: :analyzable_resource,
    target: AshDyan.Dsl.Domain.AnalyzableResource,
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

  @dynal %Spark.Dsl.Section{
    name: :dynal,
    describe: """
    Declares which resources in this domain are analyzable, for discovery.

    This is a thin registry. Cross-resource joins are out of scope for v1.
    """,
    entities: [
      @analyzable_resource_entity
    ],
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@dynal],
    verifiers: [AshDyan.Dsl.Domain.Verifiers.ValidateAnalyzableResources]
end
