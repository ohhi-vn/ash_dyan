defmodule AshDyan.Dsl.AnalyzableField do
  @moduledoc """
  Struct describing a single `analyzable_field` declared in the `dynal` DSL section.

  This is the security whitelist: a runtime request may only reference fields,
  functions, buckets, and percentiles that appear here.
  """

  @type t :: %__MODULE__{
          name: atom(),
          type: :frequency | :aggregate | :time_bucket | :percentile,
          functions: [AshDyan.aggregate_function()],
          buckets: [AshDyan.time_bucket()],
          percentiles: [pos_integer()],
          time_field: atom() | nil
        }

  defstruct [
    :name,
    :type,
    :functions,
    :buckets,
    :percentiles,
    :time_field,
    :__spark_metadata__
  ]
end
