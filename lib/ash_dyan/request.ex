defmodule AshDyan.Request do
  @moduledoc """
  The runtime request spec for a dynamic analysis.

  A caller sends a map (or a `t/0` struct) describing what chart data they want.
  `normalize/1` fills in defaults and `validate/1` checks it against the
  resource's `dyan` DSL whitelist.

  ## Shape

      %{
        domain: MyApp.Shop,
        resource: MyApp.Order,
        type: :time_bucket,          # :frequency | :aggregate | :time_bucket | :percentile | :histogram
        column: :total_amount,
        function: :sum,               # required for :aggregate
        bucket: :day,                 # required for :time_bucket
        time_field: :inserted_at,
        group_by: [:status],          # optional, checked against max_group_by
        percentiles: [50, 90],        # required for :percentile
        bins: 10,                     # optional for :histogram (default 10)
        bin_width: nil,               # optional for :histogram (auto-computed if nil)
        filters: %{status: "paid", region: ["EU", "US"]},
        limit: 200,
        # Presentation options (apply to every type):
        sort_by: :value,              # :value | :label
        sort_order: :desc,            # :asc | :desc
        top: nil,                     # keep the N largest slices, roll the rest into "Other"
        cumulative: false,            # running totals (time_bucket)
        normalize: nil                # :percentage to convert series to share-of-total
      }

  ## Filters

  `filters` are parsed by `Ash.Filter.parse/2`, so they support the full range
  of operators Ash understands on whitelisted fields — not just equality. For
  example:

      %{status: "paid"}                       # equality
      %{region: ["EU", "US"]}                 # membership (in)
      %{total_amount: %{gt: 100}}             # comparison
      %{inserted_at: %{between: [start, end]}} # range

  Only fields declared in `allow_filters_on` may be filtered.
  """

  @type analysis_type :: :frequency | :aggregate | :time_bucket | :percentile | :histogram
  @type sort_by :: :value | :label
  @type sort_order :: :asc | :desc
  @type t :: %__MODULE__{
          domain: module() | nil,
          resource: module(),
          type: analysis_type(),
          column: atom() | nil,
          function: AshDyan.aggregate_function() | nil,
          bucket: AshDyan.time_bucket() | nil,
          time_field: atom() | nil,
          group_by: [atom()],
          percentiles: [pos_integer()],
          bins: pos_integer() | nil,
          bin_width: number() | nil,
          filters: map(),
          limit: pos_integer() | nil,
          sort_by: sort_by() | nil,
          sort_order: sort_order(),
          top: pos_integer() | nil,
          cumulative: boolean(),
          normalize: :percentage | nil
        }

  defstruct [
    :domain,
    :resource,
    :type,
    :column,
    :function,
    :bucket,
    :time_field,
    :limit,
    :sort_by,
    :sort_order,
    :top,
    :normalize,
    group_by: [],
    percentiles: [],
    bins: nil,
    bin_width: nil,
    filters: %{},
    cumulative: false
  ]

  @doc "Normalize a request map into a `t/0` struct with defaults applied."
  @spec normalize(map() | t()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = request), do: {:ok, request}

  def normalize(%{} = map) do
    request = %__MODULE__{
      domain: get(map, :domain),
      resource: get(map, :resource),
      type: normalize_atom(get(map, :type)),
      column: normalize_atom(get(map, :column)),
      function: normalize_atom(get(map, :function)),
      bucket: normalize_atom(get(map, :bucket)),
      time_field: normalize_atom(get(map, :time_field)),
      group_by: normalize_atoms(get(map, :group_by) || []),
      percentiles: get(map, :percentiles) || [],
      bins: get(map, :bins),
      bin_width: get(map, :bin_width),
      filters: normalize_filters(get(map, :filters) || %{}),
      limit: get(map, :limit),
      sort_by: normalize_atom(get(map, :sort_by)),
      sort_order: normalize_atom(get(map, :sort_order)) || :desc,
      top: get(map, :top),
      cumulative: get(map, :cumulative) || false,
      normalize: normalize_atom(get(map, :normalize))
    }

    # For `:time_bucket`, the DSL may declare a `time_field` that differs from
    # the field `name` (e.g. `analyzable_field :total_amount, type: :time_bucket,
    # time_field: :inserted_at`). When the request does not supply an explicit
    # `:time_field`, resolve it from the declared field so the engine selects
    # the real attribute rather than a nonexistent one.
    request = resolve_time_field(request)

    {:ok, request}
  end

  def normalize(other) do
    {:error,
     AshDyan.Error.exception(
       message: "request must be a map or AshDyan.Request, got #{inspect(other)}"
     )}
  end

  # For `:time_bucket`, the DSL may declare a `time_field` that differs from
  # the field `name` (e.g. `analyzable_field :total_amount, type: :time_bucket,
  # time_field: :inserted_at`). When the request does not supply an explicit
  # `:time_field`, resolve it from the declared field so the engine selects
  # the real attribute rather than a nonexistent one.
  defp resolve_time_field(
         %__MODULE__{type: :time_bucket, time_field: nil, column: column, resource: resource} =
           request
       ) do
    case AshDyan.Info.analyzable_field(resource, column, :time_bucket) do
      %{time_field: time_field} when not is_nil(time_field) ->
        %{request | time_field: time_field}

      _ ->
        request
    end
  end

  defp resolve_time_field(request), do: request

  # Reads a key that may be present as either an atom or a string key.
  defp get(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  # Accept both atom and string keys/values so requests coming from an HTTP
  # adapter (which carry string keys) work without manual coercion.
  defp normalize_atom(nil), do: nil
  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    # Only atoms already loaded in the VM can be referenced. Every
    # legitimately-whitelisted atom already exists (it is declared in the
    # resource's `dyan` DSL), so a failure here means genuinely bogus input.
    # Return the raw string so downstream whitelist lookups simply don't match,
    # yielding a clean `:not_analyzable`/`:not_allowed` error instead of a crash.
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_atom(value), do: value

  defp normalize_atoms(list) when is_list(list) do
    Enum.map(list, &normalize_atom/1)
  end

  defp normalize_atoms(other), do: other

  defp normalize_filters(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {normalize_atom(k), v} end)
  end

  defp normalize_filters(other), do: other

  @doc """
  Validate a normalized request against the resource's `dyan` DSL whitelist.

  Returns `:ok` or `{:error, %AshDyan.Error{}}` naming the offending field.

  ## Error reasons

  The `reason` field of the returned `AshDyan.Error` is one of:

  - `:not_a_resource` / `:not_analyzable` — the `:resource` is invalid or has
    no `dyan` configuration.
  - `:unknown_type` — `:type` is not one of the capabilities.
  - `:not_analyzable` — `:column`/`time_field` is not whitelisted for the type.
  - `:not_allowed` — `:function`/`:bucket`/`:percentiles` is not in the
    whitelist for that field, or `:filters` references a non-allowed field.
  - `:too_many` — `:group_by` exceeds `max_group_by`.
  - `:too_large` — `:limit` exceeds `max_limit`.
  - `:bad_bins` — `:bins`/`:bin_width` is of the wrong type or non-positive.
  - `:unknown_attribute` — `:group_by` references a non-existent attribute.
  - `:bad_type` — `:filters`/`limit` is of the wrong type.
  """
  @spec validate(t()) :: :ok | {:error, AshDyan.Error.t()}
  def validate(%__MODULE__{} = request) do
    with :ok <- validate_resource_present(request),
         :ok <- validate_type_specific(request),
         :ok <- validate_common(request),
         :ok <- validate_group_by(request),
         :ok <- validate_filters(request) do
      validate_limit(request)
    end
  end

  # Dispatch to the analysis module registered for the request's `:type`. This
  # keeps the per-type whitelist checks (column/function/bucket/percentiles/
  # bins) in one place per type and makes the set of analysis types open.
  # An unregistered `:type` is reported as `:unknown_type`.
  defp validate_type_specific(%{type: type} = request) do
    case AshDyan.Analysis.Registry.fetch(type) do
      {:ok, module} ->
        module.validate(request)

      :error ->
        {:error,
         AshDyan.Error.exception(
           field: :type,
           reason: :unknown_type,
           message:
             "type must be one of #{inspect(AshDyan.Analysis.Registry.types())}, got #{inspect(type)}"
         )}
    end
  end

  # Validates the cross-cutting presentation options (sorting, top-N, cumulative,
  # percentage normalization). These apply to every analysis type, but each type
  # may reject options that would corrupt its axis semantics (e.g. sorting a
  # time series out of chronological order).
  defp validate_common(%{type: type} = request) do
    with :ok <- validate_presentation_values(request),
         :ok <- validate_presentation_supported(type, request) do
      :ok
    end
  end

  defp validate_presentation_values(%{
         sort_by: sort_by,
         sort_order: sort_order,
         normalize: normalize,
         top: top
       }) do
    cond do
      sort_by not in [nil, :value, :label] ->
        {:error,
         AshDyan.Error.exception(
           field: :sort_by,
           reason: :bad_type,
           message: ":sort_by must be :value or :label, got #{inspect(sort_by)}"
         )}

      sort_order not in [:asc, :desc] ->
        {:error,
         AshDyan.Error.exception(
           field: :sort_order,
           reason: :bad_type,
           message: ":sort_order must be :asc or :desc, got #{inspect(sort_order)}"
         )}

      normalize not in [nil, :percentage] ->
        {:error,
         AshDyan.Error.exception(
           field: :normalize,
           reason: :bad_type,
           message: ":normalize must be :percentage or nil, got #{inspect(normalize)}"
         )}

      not is_nil(top) and not (is_integer(top) and top > 0) ->
        {:error,
         AshDyan.Error.exception(
           field: :top,
           reason: :bad_type,
           message: ":top must be a positive integer, got #{inspect(top)}"
         )}

      true ->
        :ok
    end
  end

  # Reject presentation options the analysis type explicitly does not support.
  defp validate_presentation_supported(type, %{
         sort_by: sort_by,
         top: top,
         cumulative: cumulative,
         normalize: normalize
       }) do
    active =
      []
      |> then(fn acc -> if sort_by, do: [:sort_by | acc], else: acc end)
      |> then(fn acc -> if top, do: [:top | acc], else: acc end)
      |> then(fn acc -> if cumulative, do: [:cumulative | acc], else: acc end)
      |> then(fn acc -> if normalize, do: [:normalize | acc], else: acc end)

    case AshDyan.Analysis.Registry.fetch(type) do
      {:ok, module} ->
        # Third-party analysis modules may not implement `supports_presentation?/1`;
        # treat an unimplemented callback as "supports everything" so they keep
        # working without changes.
        supports? =
          if function_exported?(module, :supports_presentation?, 1) do
            &module.supports_presentation?/1
          else
            fn _ -> true end
          end

        unsupported = Enum.reject(active, supports?)

        if unsupported == [] do
          :ok
        else
          {:error,
           AshDyan.Error.exception(
             field: hd(unsupported),
             reason: :not_supported,
             message:
               "presentation option #{inspect(hd(unsupported))} is not supported for analysis type :#{type}"
           )}
        end

      :error ->
        :ok
    end
  end

  defp validate_resource_present(%{resource: nil}) do
    {:error, AshDyan.Error.exception(field: :resource, message: "request is missing :resource")}
  end

  defp validate_resource_present(%{resource: resource}) do
    if Ash.Resource.Info.resource?(resource) do
      if AshDyan.Info.analyzable?(resource) do
        :ok
      else
        {:error,
         AshDyan.Error.exception(
           field: :resource,
           reason: :not_analyzable,
           message: "#{inspect(resource)} is not analyzable (no `dyan` section)"
         )}
      end
    else
      {:error,
       AshDyan.Error.exception(
         field: :resource,
         reason: :not_a_resource,
         message: "#{inspect(resource)} is not an Ash resource"
       )}
    end
  end

  defp validate_group_by(%{resource: resource, group_by: group_by}) do
    max = AshDyan.Info.max_group_by(resource)

    if length(group_by) > max do
      {:error,
       AshDyan.Error.exception(
         field: :group_by,
         reason: :too_many,
         message: "group_by has #{length(group_by)} fields but the maximum is #{max}"
       )}
    else
      case Enum.reject(group_by, &Ash.Resource.Info.attribute(resource, &1)) do
        [] ->
          :ok

        unknown ->
          {:error,
           AshDyan.Error.exception(
             field: :group_by,
             reason: :unknown_attribute,
             message:
               "group_by references non-existent attributes #{inspect(unknown)} on #{inspect(resource)}"
           )}
      end
    end
  end

  defp validate_filters(%{resource: resource, filters: filters}) when is_map(filters) do
    allowed = AshDyan.Info.allow_filters_on(resource)
    keys = Map.keys(filters)

    invalid = Enum.reject(keys, fn key -> key in allowed end)

    if invalid == [] do
      :ok
    else
      {:error,
       AshDyan.Error.exception(
         field: :filters,
         reason: :not_allowed,
         message:
           "filters on #{inspect(invalid)} are not allowed; allowed filter fields: #{inspect(allowed)}"
       )}
    end
  end

  defp validate_filters(%{filters: filters}) do
    {:error,
     AshDyan.Error.exception(
       field: :filters,
       reason: :bad_type,
       message: ":filters must be a map, got #{inspect(filters)}"
     )}
  end

  defp validate_limit(%{limit: nil}), do: :ok

  defp validate_limit(%{resource: resource, limit: limit}) when is_integer(limit) and limit > 0 do
    max = AshDyan.Info.max_limit(resource)

    if limit > max do
      {:error,
       AshDyan.Error.exception(
         field: :limit,
         reason: :too_large,
         message: "limit #{limit} exceeds the maximum of #{max}"
       )}
    else
      :ok
    end
  end

  defp validate_limit(%{limit: limit}) do
    {:error,
     AshDyan.Error.exception(
       field: :limit,
       reason: :bad_type,
       message: ":limit must be a positive integer, got #{inspect(limit)}"
     )}
  end
end
