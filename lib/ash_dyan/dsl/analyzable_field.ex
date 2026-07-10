defmodule AshDyan.Dsl.AnalyzableField do
  @moduledoc """
  Struct describing a single `analyzable_field` declared in the `dyan` DSL section.

  This is the security whitelist: a runtime request may only reference fields,
  functions, buckets, and percentiles that appear here.
  """

  @type t :: %__MODULE__{
          name: atom(),
          type: :frequency | :aggregate | :time_bucket | :percentile | :histogram,
          functions: [AshDyan.aggregate_function()],
          buckets: [AshDyan.time_bucket()],
          percentiles: [pos_integer()],
          bins: pos_integer(),
          bin_width: number() | nil,
          time_field: atom() | nil
        }

  defstruct [
    :name,
    :type,
    :functions,
    :buckets,
    :percentiles,
    :bins,
    :bin_width,
    :time_field,
    :__spark_metadata__
  ]
end
