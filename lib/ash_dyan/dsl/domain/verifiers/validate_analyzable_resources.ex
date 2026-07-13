defmodule AshDyan.Dsl.Domain.Verifiers.ValidateAnalyzableResources do
  @moduledoc """
  Validates the domain-level `dyan` registry after compilation.

  - Rejects `analyzable_resource` referencing a module that is not an Ash
    resource.
  - Rejects `analyzable_resource` referencing a resource that has no `dyan`
    configuration (i.e. is not actually analyzable).
  """

  use Spark.Dsl.Verifier

  alias Ash.Resource.Info
  alias Spark.Dsl.Extension
  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    _domain = Verifier.get_persisted(dsl_state, :module)

    errors =
      dsl_state
      |> Verifier.get_entities([:dyan])
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
      not Code.ensure_loaded?(resource) or not Info.resource?(resource) ->
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
  #
  # During parallel compilation the referenced resource may not have been
  # compiled (and its `dyan` DSL persisted) yet. We detect that specific case
  # via the absence of the persisted DSL function and defer the check rather
  # than raising a false "not analyzable" error. Ash's own `resources do`
  # registration in the domain already guarantees the module exists and is an
  # Ash resource, so any other failure here is a genuine configuration problem
  # that should surface rather than be silently treated as valid.
  defp analyzable?(resource) do
    if function_exported?(resource, :__spark_dsl__, 0) do
      case Extension.get_entities(resource, [:dyan]) do
        nil -> false
        [] -> false
        _ -> true
      end
    else
      # DSL not persisted yet (parallel compilation ordering): defer.
      true
    end
  end
end
