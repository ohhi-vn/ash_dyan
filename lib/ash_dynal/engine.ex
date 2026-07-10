defmodule AshDynal.Engine do
  @moduledoc """
  Translates a validated `AshDynal.Request` into an `Ash.Query`, runs it through
  the resource's normal read action (so Ash policies apply), and aggregates the
  result in memory into a chart-ready shape.

  ## Design note

  Ash's `Ash.Query` (3.x) does not expose a generic `group_by` builder, and the
  shape of grouped aggregates is data-layer dependent. To keep AshDynal
  data-layer agnostic, safe, and predictable, the engine:

  1. selects only the columns it needs (the metric column, the time field, the
     group_by fields, and the filter fields),
  2. applies the caller's filters and the configured `limit` (a hard cap that
     prevents full-cardinality group-bys from blowing up the DB),
  3. runs the query through the resource's read action — so `Ash.Policy`
     authorization applies unchanged,
  4. aggregates the returned rows in memory into the stable `labels`/`series`
     output shape.

  This keeps the security boundary (the `dynal` DSL whitelist + enforced limits)
  intact while avoiding data-layer-specific query shapes. Percentiles, in
  particular, are computed in memory so they work on any data layer; the
  capability check still surfaces data-layer limits explicitly via
  `AshDynal.supports?/2`.
  """

  alias AshDynal.{Request, Result}

  @doc "Build an `Ash.Query` that selects exactly the columns needed for the request."
  @spec build_query(Request.t(), [AshDynal.run_opt()]) ::
          {:ok, Ash.Query.t()} | {:error, term()}
  def build_query(%Request{} = request, opts \\ []) do
    resource = request.resource

    capability = request.type

    unless AshDynal.DataLayer.supports?(resource, capability) do
      {:error,
       AshDynal.Error.exception(
         field: :type,
         reason: :unsupported_data_layer,
         message:
           "analysis type #{capability} is not supported by the #{inspect(resource)} data layer"
       )}
    end

    query =
      resource
      |> Ash.Query.for_read(:read)
      |> apply_select(request)
      |> apply_filters(request)
      |> apply_limit(request)
      |> apply_timeout(request, opts)

    {:ok, query}
  end

  defp apply_select(query, %{type: :frequency, column: column, group_by: group_by}) do
    Ash.Query.select(query, Enum.uniq([column | group_by]))
  end

  defp apply_select(query, %{type: :aggregate, column: column, group_by: group_by}) do
    Ash.Query.select(query, Enum.uniq([column | group_by]))
  end

  defp apply_select(query, %{
         type: :time_bucket,
         column: column,
         time_field: time_field,
         group_by: group_by
       }) do
    time_field = time_field || column
    Ash.Query.select(query, Enum.uniq([time_field, column | group_by]))
  end

  defp apply_select(query, %{type: :percentile, column: column, group_by: group_by}) do
    Ash.Query.select(query, Enum.uniq([column | group_by]))
  end

  defp apply_filters(query, %{filters: filters}) when filters == %{}, do: query

  defp apply_filters(query, %{filters: filters}) do
    # `filter_input` honors field policies on the resource, treating this as
    # external input — never a bypass of authorization.
    Ash.Query.filter_input(query, filters)
  end

  defp apply_limit(query, %{limit: nil} = request) do
    Ash.Query.limit(query, AshDynal.Info.default_limit(request.resource))
  end

  defp apply_limit(query, %{limit: limit}) do
    Ash.Query.limit(query, limit)
  end

  defp apply_timeout(query, _request, opts) do
    case Keyword.get(opts, :timeout) do
      nil -> query
      timeout -> Ash.Query.timeout(query, timeout)
    end
  end

  @doc "Run a built query through the resource's read action."
  @spec run_query(Ash.Query.t(), Request.t(), [AshDynal.run_opt()]) ::
          {:ok, [Ash.Resource.Record.t()]} | {:error, term()}
  def run_query(query, _request, opts) do
    read_opts = []

    read_opts =
      if actor = Keyword.get(opts, :actor) do
        [actor: actor | read_opts]
      else
        read_opts
      end

    read_opts =
      if tenant = Keyword.get(opts, :tenant) do
        [tenant: tenant | read_opts]
      else
        read_opts
      end

    query =
      if data = Keyword.get(opts, :data) do
        # `Ash.DataLayer.Simple` (in-memory / embedded) does not persist; callers
        # may supply the dataset directly. This is also the supported path for
        # tests.
        Ash.DataLayer.Simple.set_data(query, data)
      else
        query
      end

    Ash.read(query, read_opts)
  end
end
