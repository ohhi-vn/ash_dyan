defmodule AshDyan.Analysis do
  @moduledoc """
  Behaviour for a single analysis capability (frequency, aggregate, time_bucket,
  percentile, histogram, ...).

  AshDyan's analysis types were previously a closed sum type scattered across
  parallel `case`/`when` clauses in `AshDyan.Request`, `AshDyan.Engine`,
  `AshDyan.Engine.Formatter`, and `AshDyan.Charts`. Implementing this behaviour
  and registering the module under `config :ash_dyan, :analysis_types` lets a
  downstream app add a new analysis type (e.g. `:funnel`, `:cohort`) without
  forking AshDyan.

  ## Example

      defmodule MyApp.AshDyan.Funnel do
        @behaviour AshDyan.Analysis
        # ... implement the four callbacks ...
      end

      # config/config.exs
      config :ash_dyan, :analysis_types, %{funnel: MyApp.AshDyan.Funnel}

  The request's `:type` is the registry key.
  """

  alias AshDyan.{Request, Result}

  @callback validate(Request.t()) :: :ok | {:error, AshDyan.Error.t()}
  @callback select_fields(Request.t()) :: [atom()]
  @callback format(Request.t(), [Ash.Resource.Record.t()]) ::
              {:ok, Result.t()} | {:error, term()}
  @callback recommend_chart(Result.t()) :: AshDyan.Charts.chart_type()

  # Which cross-cutting presentation options a type supports. `:frequency` and
  # `:aggregate` allow the full set (sort/top/cumulative/normalize); ordered-axis
  # types reject the options that would corrupt their axis ordering.
  @callback supports_presentation?(atom()) :: boolean()

  # Default implementation: every presentation option is allowed. Analysis
  # modules override this to reject options that don't make sense for their
  # axis semantics.
  def supports_presentation?(_option), do: true
end

defmodule AshDyan.Analysis.Registry do
  @moduledoc """
  Maps an analysis `:type` atom to its `AshDyan.Analysis` implementation.

  Built-in types are merged with `config :ash_dyan, :analysis_types`, so
  third-party analysis types can be registered without patching AshDyan.
  """

  @builtin %{
    frequency: AshDyan.Analysis.Frequency,
    aggregate: AshDyan.Analysis.Aggregate,
    time_bucket: AshDyan.Analysis.TimeBucket,
    percentile: AshDyan.Analysis.Percentile,
    histogram: AshDyan.Analysis.Histogram
  }

  @doc "Returns `{:ok, module}` or `:error`."
  @spec fetch(atom()) :: {:ok, module()} | :error
  def fetch(type) do
    Map.fetch(all(), type)
  end

  @doc "All registered analysis types (built-in merged with app config)."
  @spec all() :: %{atom() => module()}
  def all do
    Map.merge(@builtin, Application.get_env(:ash_dyan, :analysis_types, %{}))
  end

  @doc "The list of known analysis type atoms."
  @spec types() :: [atom()]
  def types, do: Map.keys(all())
end
