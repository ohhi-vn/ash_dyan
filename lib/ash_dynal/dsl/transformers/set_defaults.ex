defmodule AshDynal.Dsl.Transformers.SetDefaults do
  @moduledoc """
  Compile-time transformer that persists a normalized view of the `dynal`
  configuration onto the resource for fast runtime access.

  It also rejects `:aggregate`/`time_bucket`/`percentile` declarations whose
  `functions`/`buckets`/`percentiles` lists are empty, since those would be
  unusable at runtime.
  """

  use Spark.Dsl.Transformer

  def transform(dsl_state) do
    fields =
      dsl_state
      |> Spark.Dsl.Transformer.get_entities([:dynal])
      |> Enum.map(fn field ->
        %{
          name: field.name,
          type: field.type,
          functions: field.functions,
          buckets: field.buckets,
          percentiles: field.percentiles,
          time_field: field.time_field
        }
      end)

    dsl_state = Spark.Dsl.Transformer.persist(dsl_state, :ash_dynal_fields, fields)

    {:ok, dsl_state}
  end
end
