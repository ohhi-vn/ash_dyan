defmodule AshDynal.Dsl.Domain.Verifiers.ValidateAnalyzableResources do
  @moduledoc """
  Validates the domain-level `dynal` registry after compilation.

  - Rejects `analyzable_resource` referencing a module that is not an Ash
    resource.
  - Rejects `analyzable_resource` referencing a resource that has no `dynal`
    configuration (i.e. is not actually analyzable).
  """

  use Spark.Dsl.Verifier

  def verify(dsl_state) do
    domain = Spark.Dsl.Transformer.get_persisted(dsl_state, :module)

    errors =
      dsl_state
      |> Spark.Dsl.Transformer.get_entities([:dynal])
      |> Enum.flat_map(fn %{resource: resource} ->
        validate_resource(domain, resource)
      end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end

  defp validate_resource(domain, resource) do
    cond do
      not Code.ensure_loaded?(resource) or not Ash.Resource.Info.resource?(resource) ->
        ["dynal: analyzable_resource #{inspect(resource)} is not an Ash resource"]

      not AshDynal.Info.analyzable?(resource) ->
        [
          "dynal: analyzable_resource #{inspect(resource)} has no `dynal` configuration; " <>
            "add `extensions: [AshDynal]` and a `dynal` section to it"
        ]

      true ->
        []
    end
  end
end
