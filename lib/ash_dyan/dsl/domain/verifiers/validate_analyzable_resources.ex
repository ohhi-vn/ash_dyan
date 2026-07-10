defmodule AshDyan.Dsl.Domain.Verifiers.ValidateAnalyzableResources do
  @moduledoc """
  Validates the domain-level `dyan` registry after compilation.

  - Rejects `analyzable_resource` referencing a module that is not an Ash
    resource.
  - Rejects `analyzable_resource` referencing a resource that has no `dyan`
    configuration (i.e. is not actually analyzable).
  """

  use Spark.Dsl.Verifier

  def verify(dsl_state) do
    _domain = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    errors =
      dsl_state
      |> Spark.Dsl.Verifier.get_entities([:dyan])
      |> Enum.flat_map(fn %{resource: resource} ->
        validate_resource(resource)
      end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end

  defp validate_resource(resource) do
    cond do
      not Code.ensure_loaded?(resource) or not Ash.Resource.Info.resource?(resource) ->
        ["dyan: analyzable_resource #{inspect(resource)} is not an Ash resource"]

      not analyzable?(resource) ->
        [
          "dyan: analyzable_resource #{inspect(resource)} has no `dyan` configuration; " <>
            "add `extensions: [AshDyan]` and a `dyan` section to it"
        ]

      true ->
        []
    end
  end

  # Check analyzability directly via the DSL state to avoid a compile-time
  # dependency on the `AshDyan` module (which would create a cycle through
  # this verifier and break Spark's `use` macro expansion).
  defp analyzable?(resource) do
    case Spark.Dsl.Extension.get_entities(resource, [:dyan]) do
      nil -> false
      [] -> false
      _ -> true
    end
  end
end
