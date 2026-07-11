defmodule AshDyan.Engine do
  @moduledoc """
  Translates a validated `AshDyan.Request` into an `Ash.Query`, runs it through
  the resource's normal read action (so Ash policies apply), and aggregates the
  result in memory into a chart-ready shape.

  ## Design note

  Ash's `Ash.Query` (3.x) does not expose a generic `group_by` builder, and the
  shape of grouped aggregates is data-layer dependent. To keep AshDyan
  data-layer agnostic, safe, and predictable, the engine:

  1. selects only the columns it needs (the metric column, the time field, the
     group_by fields),
  2. applies the caller's filters and the configured `limit` (a hard cap that
     prevents full-cardinality group-bys from blowing up the DB),
  3. runs the query through the resource's read action — so `Ash.Policy`
     authorization applies unchanged,
  4. aggregates the returned rows in memory into the stable `labels`/`series`
     output shape.

  This keeps the security boundary (the `dyan` DSL whitelist + enforced limits)
  intact while avoiding data-layer-specific query shapes. Percentiles, in
  particular, are computed in memory so they work on any data layer; the
  capability check still surfaces data-layer limits explicitly via
  `AshDyan.supports?/2`.
  """

  alias Ash.DataLayer
  alias AshDyan.{DataLayer, Error, Info, Request}
  require Logger

  @doc "Build an `Ash.Query` that selects exactly the columns needed for the request."
  @spec build_query(Request.t(), [AshDyan.run_opt()]) ::
          {:ok, Ash.Query.t()} | {:error, term()}
  def build_query(%Request{} = request, opts \\ []) do
    resource = request.resource
    capability = request.type

    if DataLayer.supports?(resource, capability) do
      case primary_read_action(resource) do
        {:ok, action_name} ->
          base_query =
            resource
            |> Ash.Query.for_read(action_name, %{}, domain: request.domain)
            |> apply_select(request)
            |> apply_limit(request)
            |> apply_timeout(request, opts)

          case apply_filters(base_query, request) do
            {:error, _} = error -> error
            query -> {:ok, query}
          end

        {:error, _} = error ->
          error
      end
    else
      Logger.warning(fn ->
        "AshDyan: analysis type #{capability} is not supported by the " <>
          "#{inspect(resource)} data layer"
      end)

      {:error,
       Error.exception(
         field: :type,
         reason: :unsupported_data_layer,
         message:
           "analysis type #{capability} is not supported by the #{inspect(resource)} data layer"
       )}
    end
  end

  # Resolves the resource's actual primary read action instead of assuming a
  # literal `:read` action exists.
  defp primary_read_action(resource) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      %{name: name} ->
        {:ok, name}

      nil ->
        {:error,
         Error.exception(
           field: :resource,
           reason: :no_primary_read_action,
           message: "#{inspect(resource)} has no primary :read action for AshDyan to use"
         )}
    end
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

  defp apply_select(query, %{type: :histogram, column: column, group_by: group_by}) do
    Ash.Query.select(query, Enum.uniq([column | group_by]))
  end

  defp apply_filters(query, %{filters: filters}) when filters == %{}, do: query

  defp apply_filters(query, %{filters: filters}) do
    # Request filters are parsed internally via `Ash.Filter.parse/2` rather than
    # `Ash.Query.filter_input/2`. This is a deliberate choice: `filter_input`
    # honors Ash field policies (which require `public?` attributes and actor
    # context), whereas our `dyan` DSL whitelist (`allow_filters_on`) is the
    # security boundary that already restricts which fields may be filtered.
    # Using `filter_input` here would silently change behavior for resources that
    # declare field policies, so do not "fix" this mismatch by swapping to it
    # without revisiting the security model.
    #
    # A parse failure here means the request passed our whitelist but Ash still
    # could not build the filter (e.g. a type mismatch). We surface it as a
    # structured error rather than silently dropping the filter, which would
    # return a wider, incorrect result set.
    case Ash.Filter.parse(query.resource, filters) do
      {:ok, filter} ->
        Ash.Query.do_filter(query, filter)

      {:error, reason} ->
        {:error,
         Error.exception(
           field: :filters,
           reason: :invalid_value,
           message: "could not parse filters #{inspect(filters)}: #{inspect(reason)}"
         )}
    end
  end

  defp apply_limit(query, %{limit: nil} = request) do
    Ash.Query.limit(query, Info.default_limit(request.resource))
  end

  defp apply_limit(query, %{limit: limit}) do
    Ash.Query.limit(query, limit)
  end

  defp apply_timeout(query, request, opts) do
    timeout =
      case Keyword.get(opts, :timeout) do
        nil -> Info.query_timeout(request.resource)
        timeout -> timeout
      end

    # The `Ash.DataLayer.Simple` (ETS) layer does not support query timeouts,
    # so only apply one when the underlying data layer can honor it. This keeps
    # the `query_timeout` guarantee on real data layers (Postgres, etc.) without
    # breaking the in-memory path used by tests and embedded resources.
    if Ash.DataLayer.data_layer_can?(request.resource, :timeout) do
      Ash.Query.timeout(query, timeout)
    else
      query
    end
  end

  @doc "Run a built query through the resource's read action."
  @spec run_query(Ash.Query.t(), Request.t(), [AshDyan.run_opt()]) ::
          {:ok, [Ash.Resource.Record.t()]} | {:error, term()}
  def run_query(query, request, opts) do
    read_opts = []

    read_opts =
      if domain = request.domain do
        Keyword.put(read_opts, :domain, domain)
      else
        read_opts
      end

    read_opts =
      if actor = Keyword.get(opts, :actor) do
        Keyword.put(read_opts, :actor, actor)
      else
        read_opts
      end

    read_opts =
      if tenant = Keyword.get(opts, :tenant) do
        Keyword.put(read_opts, :tenant, tenant)
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
