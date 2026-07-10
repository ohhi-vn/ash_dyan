defmodule AshDynal do
  @moduledoc """
  AshDynal — runtime-driven dynamic analysis for any Ash resource.

  AshDynal is a standalone Ash extension (no dependency on `ash_phoenix_gen_api`)
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

  The `dynal` DSL is a whitelist. A runtime request can only reference fields,
  functions, buckets, and filter targets declared there — this is what makes
  "arbitrary column + arbitrary filter from the client" safe rather than an
  injection/DoS vector.

  ## Entry point

  `AshDynal.run/1` (or `AshDynal.run/2` with an `actor` for policy checks) is the
  single entry point. It validates the spec, builds an `Ash.Query`, runs it
  through the resource's normal read action (so Ash policies/authorization still
  apply), and formats the result.

  See `AshDynal.Request` for the request spec shape and `AshDynal.Info` for
  introspection helpers.
  """

  alias AshDynal.{Request, Result}

  use AshDynal.Dsl.Extension

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
  - `:timeout` — overrides the query timeout for this request.

  Returns `{:ok, %AshDynal.Result{}}` or `{:error, error}`.
  """
  @spec run(Request.t() | map(), [run_opt()]) :: {:ok, Result.t()} | {:error, term()}
  def run(%{} = spec, opts \\ []) do
    with {:ok, request} <- Request.normalize(spec),
         :ok <- Request.validate(request),
         {:ok, query} <- AshDynal.Engine.build_query(request, opts),
         {:ok, records} <- AshDynal.Engine.run_query(query, request, opts),
         {:ok, result} <- Result.format(request, records) do
      {:ok, result}
    else
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Same as `run/2` but raises on error.
  """
  @spec run!(Request.t() | map(), [run_opt()]) :: Result.t()
  def run!(spec, opts \\ []) do
    case run(spec, opts) do
      {:ok, result} -> result
      {:error, error} -> raise AshDynal.Error, error
    end
  end

  @doc """
  Returns true if the resource's data layer supports the given capability.

  Capabilities: `:frequency`, `:aggregate`, `:time_bucket`, `:percentile`.

  This is surfaced explicitly so callers can discover data-layer limits before
  issuing a query, rather than discovering them at query time.
  """
  @spec supports?(module(), AshDynal.capability()) :: boolean()
  def supports?(resource, capability) do
    AshDynal.DataLayer.supports?(resource, capability)
  end

  @typedoc "Analysis capabilities exposed by AshDynal."
  @type capability :: :frequency | :aggregate | :time_bucket | :percentile

  @typedoc "Numeric aggregate functions."
  @type aggregate_function :: :sum | :avg | :min | :max

  @typedoc "Time bucket granularities."
  @type time_bucket :: :minute | :hour | :day | :week | :month | :quarter | :year
end
