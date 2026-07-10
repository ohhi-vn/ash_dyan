defmodule AshDynal.Dsl.Extension do
  @moduledoc """
  The `AshDynal` Spark DSL extension for resources.

  Adds a `dynal do ... end` section to a resource declaring which fields are
  analyzable and how. This is the security boundary: the runtime request can
  only reference fields, functions, buckets, and filter targets declared here.

  ## Example

      defmodule MyApp.Order do
        use Ash.Resource, extensions: [AshDynal]

        dynal do
          analyzable_field :status, type: :frequency
          analyzable_field :total_amount, type: :aggregate, functions: [:sum, :avg, :min, :max]
          analyzable_field :inserted_at, type: :time_bucket, buckets: [:day, :week, :month]
          analyzable_field :total_amount, type: :percentile, percentiles: [50, 90, 99]

          max_group_by 3
          default_limit 100
          max_limit 1000
          allow_filters_on [:status, :region, :inserted_at]
        end
      end
  """

  @doc false
  def analyzable_field_entity do
    %Spark.Dsl.Entity{
      name: :analyzable_field,
      target: AshDynal.Dsl.AnalyzableField,
      describe: "Declares a field as analyzable for a given analysis type.",
      args: [:name, :type],
      schema: [
        name: [
          type: :atom,
          required: true,
          doc: "The attribute (or, for percentiles, the numeric field) to analyze."
        ],
        type: [
          type: {:one_of, [:frequency, :aggregate, :time_bucket, :percentile]},
          required: true,
          doc: "The kind of analysis this declaration enables."
        ],
        functions: [
          type: {:list, {:one_of, [:sum, :avg, :min, :max]}},
          required: false,
          default: [],
          doc: "For `:aggregate`, which functions are allowed."
        ],
        buckets: [
          type: {:list, {:one_of, [:minute, :hour, :day, :week, :month, :quarter, :year]}},
          required: false,
          default: [],
          doc: "For `:time_bucket`, which bucket granularities are allowed."
        ],
        percentiles: [
          type: {:list, :pos_integer},
          required: false,
          default: [],
          doc: "For `:percentile`, which percentile values are allowed."
        ],
        time_field: [
          type: :atom,
          required: false,
          doc: "For `:time_bucket`, the time attribute to bucket on (defaults to `name`)."
        ]
      ],
      transform: {__MODULE__, :normalize_analyzable_field, []}
    }
  end

  @doc false
  def normalize_analyzable_field(%{type: :time_bucket} = entity) do
    {:ok, %{entity | time_field: entity.time_field || entity.name}}
  end

  def normalize_analyzable_field(entity), do: {:ok, entity}

  @dynal %Spark.Dsl.Section{
    name: :dynal,
    describe: """
    Declares which fields of a resource may be analyzed at runtime, and how.

    This is a whitelist. The runtime request can only reference fields,
    functions, buckets, and filter targets declared here.
    """,
    entities: [
      analyzable_field_entity()
    ],
    schema: [
      max_group_by: [
        type: :pos_integer,
        required: false,
        default: 3,
        doc: "Maximum number of group_by fields a request may specify."
      ],
      default_limit: [
        type: :pos_integer,
        required: false,
        default: 100,
        doc: "Default row limit applied when a request does not specify one."
      ],
      max_limit: [
        type: :pos_integer,
        required: false,
        default: 1000,
        doc: "Maximum row limit a request may specify (hard cap)."
      ],
      query_timeout: [
        type: :pos_integer,
        required: false,
        default: 15_000,
        doc: "Per-request query timeout in milliseconds."
      ],
      allow_filters_on: [
        type: {:list, :atom},
        required: false,
        default: [],
        doc: "Attributes that a runtime request is allowed to filter on."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@dynal],
    transformers: [AshDynal.Dsl.Transformers.SetDefaults],
    verifiers: [AshDynal.Dsl.Verifiers.ValidateAnalyzableFields]
end
