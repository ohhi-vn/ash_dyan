defmodule AshDyan.Dsl.Verifiers.ValidateAnalyzableFields do
  @moduledoc """
  Validates the `dyan` DSL configuration after compilation.

  - Rejects `analyzable_field` referencing a non-existent attribute.
  - Rejects `:aggregate` declarations with no `functions`.
  - Rejects `:time_bucket` declarations with no `buckets`.
  - Rejects `:percentile` declarations with no `percentiles`.
  - Rejects `:frequency` declarations on a non-attribute.
  """

  use Spark.Dsl.Verifier

  alias Ash.Resource.Info
  alias AshDyan.Dsl.AnalyzableField
  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    errors =
      dsl_state
      |> Verifier.get_entities([:dyan])
      |> Enum.flat_map(fn field -> validate_field(resource, field) end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end

  defp validate_field(resource, %AnalyzableField{type: :frequency, name: name} = _field) do
    if attribute_exists?(resource, name) do
      []
    else
      ["dyan: analyzable_field :#{name} (frequency) references a non-existent attribute"]
    end
  end

  defp validate_field(_resource, %AnalyzableField{type: :aggregate, name: name, functions: []}) do
    ["dyan: analyzable_field :#{name} (aggregate) must declare at least one function"]
  end

  defp validate_field(resource, %AnalyzableField{type: :aggregate, name: name} = _field) do
    if attribute_exists?(resource, name) do
      []
    else
      ["dyan: analyzable_field :#{name} (aggregate) references a non-existent attribute"]
    end
  end

  defp validate_field(_resource, %AnalyzableField{type: :time_bucket, name: name, buckets: []}) do
    ["dyan: analyzable_field :#{name} (time_bucket) must declare at least one bucket"]
  end

  defp validate_field(resource, %AnalyzableField{
         type: :time_bucket,
         name: name,
         time_field: time_field
       }) do
    if attribute_exists?(resource, time_field || name) do
      []
    else
      ["dyan: analyzable_field :#{name} (time_bucket) references a non-existent time attribute"]
    end
  end

  defp validate_field(_resource, %AnalyzableField{type: :percentile, name: name, percentiles: []}) do
    ["dyan: analyzable_field :#{name} (percentile) must declare at least one percentile"]
  end

  defp validate_field(resource, %AnalyzableField{type: :percentile, name: name} = _field) do
    if attribute_exists?(resource, name) do
      []
    else
      ["dyan: analyzable_field :#{name} (percentile) references a non-existent attribute"]
    end
  end

  defp validate_field(resource, %AnalyzableField{type: :histogram, name: name} = _field) do
    if attribute_exists?(resource, name) do
      []
    else
      ["dyan: analyzable_field :#{name} (histogram) references a non-existent attribute"]
    end
  end

  defp attribute_exists?(nil, _name), do: true

  defp attribute_exists?(resource, name) do
    not is_nil(Info.attribute(resource, name))
  end
end
