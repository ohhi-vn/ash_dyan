defmodule AshDyan do
  @moduledoc """
  AshDyan — runtime-driven dynamic analysis for any Ash resource.

  AshDyan is a standalone Ash extension (no dependency on `ash_phoenix_gen_api`)
  that lets any Ash resource/domain be declared "analyzable", and exposes a
  runtime function/API where a caller sends a request spec and gets back
  chart-ready aggregated data.

  ## Positioning

  - Turns "give me a chart of X grouped by Y, filtered by Z" into a generic,
    safe, reusable runtime capability across any Ash resource — instead of
    writing a bespoke aggregate action per chart.
  - It is **not** a full BI/reporting engine, not a query builder UI, and not
    tied to Phoenix/Channels. Delivery (HTTP controller, Channel, LiveView,
    gen_api mfa) is a thin adapter on top.

  ## Security model

  The `dyan` DSL is a whitelist. A runtime request can only reference fields,
  functions, buckets, and filter targets declared there — this is what makes
  "arbitrary column + arbitrary filter from the client" safe rather than an
  injection/DoS vector.

  ## Entry point

  `AshDyan.run/1` (or `AshDyan.run/2` with an `actor` for policy checks) is the
  single entry point. It validates the spec, builds an `Ash.Query`, runs it
  through the resource's normal read action (so Ash policies/authorization still
  apply), and formats the result.

  ## Logging

  `AshDyan.run/2` emits structured logs via the `Logger` standard library:
  a `:debug` line when a request starts, a `:debug` line when a request is
  rejected during validation/configuration, a `:warning` when the requested
  analysis type is unsupported by the resource's data layer, and an `:error`
  line when the underlying read fails. Filter contents are never logged.

  See `AshDyan.Request` for the request spec shape and `AshDyan.Info` for
  introspection helpers.
  """

  require Logger

  alias AshDyan.{Request, Result}

  @analyzable_field_entity %Spark.Dsl.Entity{
    name: :analyzable_field,
    target: AshDyan.Dsl.AnalyzableField,
    describe: "Declares a field as analyzable for a given analysis type.",
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The attribute (or, for percentiles, the numeric field) to analyze."
      ],
      type: [
        type: {:one_of, [:frequency, :aggregate, :time_bucket, :percentile, :histogram]},
        required: true,
        doc: "The kind of analysis this declaration enables."
      ],
      functions: [
        type:
          {:list,
           {:one_of,
            [:sum, :avg, :min, :max, :count, :count_distinct, :stddev, :variance, :median]}},
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
      bins: [
        type: :pos_integer,
        required: false,
        default: 10,
        doc: "For `:histogram`, the default number of bins (overridable per request)."
      ],
      bin_width: [
        type: :number,
        required: false,
        doc:
          "For `:histogram`, a fixed bin width (auto-computed from the data range when omitted)."
      ],
      time_field: [
        type: :atom,
        required: false,
        doc: "For `:time_bucket`, the time attribute to bucket on (defaults to `name`)."
      ]
    ],
    transform: {__MODULE__, :normalize_analyzable_field, []}
  }

  @dyan %Spark.Dsl.Section{
    name: :dyan,
    describe: """
    Declares which fields of a resource may be analyzed at runtime, and how.

    This is a whitelist. The runtime request can only reference fields,
    functions, buckets, and filter targets declared here.
    """,
    entities: [
      @analyzable_field_entity
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
    sections: [@dyan],
    transformers: [AshDyan.Dsl.Transformers.SetDefaults],
    verifiers: [AshDyan.Dsl.Verifiers.ValidateAnalyzableFields]

  @doc false
  def normalize_analyzable_field(%{type: :time_bucket} = entity) do
    {:ok, %{entity | time_field: entity.time_field || entity.name}}
  end

  def normalize_analyzable_field(entity), do: {:ok, entity}

  @typedoc """
  Options for `run/2`.

  - `:actor` — actor passed to the read action for policy checks.
  - `:tenant` — tenant for multitenant resources.
  - `:timeout` — overrides the per-request query timeout (defaults to the
    resource's `query_timeout`, which is always enforced).
  - `:data` — explicit in-memory dataset for the `Ash.DataLayer.Simple` layer
    (used by tests and embedded resources).
  """
  @type run_opt ::
          {:actor, term()}
          | {:tenant, term()}
          | {:timeout, pos_integer() | :infinity}
          | {:data, [Ash.Resource.Record.t()]}

  @doc """
  Run a dynamic analysis request.

  ## Options

  - `:actor` — the actor to authorize as (passed to the read action).
  - `:tenant` — the tenant for multitenant resources.
  - `:timeout` — overrides the per-request query timeout (defaults to the
    resource's configured `query_timeout`, which is always enforced).
  - `:data` — an explicit in-memory dataset (`Ash.DataLayer.Simple` only). When
    supplied, the query reads from this list instead of the data layer. Mostly
    used by tests and embedded resources.

  Returns `{:ok, %AshDyan.Result{}}` or `{:error, error}`. Validation and
  configuration errors are returned as `{:error, %AshDyan.Error{}}` naming the
  offending field; read failures are returned as the underlying Ash error.
  """
  @spec run(Request.t() | map(), [run_opt()]) :: {:ok, Result.t()} | {:error, term()}
  def run(spec, opts \\ []) do
    Logger.debug(fn ->
      {resource, type} = debug_spec(spec)
      "AshDyan.run/2: starting analysis type=#{inspect(type)} resource=#{inspect(resource)}"
    end)

    with {:ok, request} <- Request.normalize(spec),
         :ok <- Request.validate(request),
         {:ok, query} <- AshDyan.Engine.build_query(request, opts),
         {:ok, records} <- AshDyan.Engine.run_query(query, request, opts),
         {:ok, result} <- Result.format(request, records) do
      {:ok, result}
    else
      {:error, %AshDyan.Error{} = error} ->
        Logger.debug(fn -> "AshDyan.run/2: rejected request: #{error.message}" end)
        {:error, error}

      {:error, other} = error ->
        Logger.error(fn -> "AshDyan.run/2: query failed: #{inspect(other)}" end)
        error
    end
  end

  defp debug_spec(%Request{} = request), do: {request.resource, request.type}

  defp debug_spec(%{} = map) do
    {Map.get(map, :resource) || Map.get(map, "resource"),
     Map.get(map, :type) || Map.get(map, "type")}
  end

  defp debug_spec(_other), do: {:unknown, nil}

  @doc """
  Same as `run/2` but raises on error.
  """
  @spec run!(Request.t() | map(), [run_opt()]) :: Result.t()
  def run!(spec, opts \\ []) do
    case run(spec, opts) do
      {:ok, result} -> result
      {:error, error} -> raise AshDyan.Error, error
    end
  end

  @doc """
  Returns true if the resource's data layer supports the given capability.

  Capabilities: `:frequency`, `:aggregate`, `:time_bucket`, `:percentile`,
  `:histogram`.

  This is surfaced explicitly so callers can discover data-layer limits before
  issuing a query, rather than discovering them at query time.
  """
  @spec supports?(module(), AshDyan.capability()) :: boolean()
  def supports?(resource, capability) do
    AshDyan.DataLayer.supports?(resource, capability)
  end

  @typedoc "Analysis capabilities exposed by AshDyan."
  @type capability :: :frequency | :aggregate | :time_bucket | :percentile | :histogram

  @typedoc "Numeric aggregate functions."
  @type aggregate_function ::
          :sum | :avg | :min | :max | :count | :count_distinct | :stddev | :variance | :median

  @typedoc "Time bucket granularities."
  @type time_bucket :: :minute | :hour | :day | :week | :month | :quarter | :year
end
