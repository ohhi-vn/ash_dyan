defmodule AshDyan.Request do
  @moduledoc """
  The runtime request spec for a dynamic analysis.

  A caller sends a map (or a `t/0` struct) describing what chart data they want.
  `normalize/1` fills in defaults and `validate/1` checks it against the
  resource's `dynal` DSL whitelist.

  ## Shape

      %{
        domain: MyApp.Shop,
        resource: MyApp.Order,
        type: :time_bucket,          # :frequency | :aggregate | :time_bucket | :percentile
        column: :total_amount,
        function: :sum,               # required for :aggregate/:percentile
        bucket: :day,                 # required for :time_bucket
        time_field: :inserted_at,
        group_by: [:status],          # optional, checked against max_group_by
        percentiles: [50, 90],        # required for :percentile
        filters: %{status: "paid", region: ["EU", "US"]},
        limit: 200
      }
  """

  @type analysis_type :: :frequency | :aggregate | :time_bucket | :percentile
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
          filters: map(),
          limit: pos_integer() | nil
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
    group_by: [],
    percentiles: [],
    filters: %{}
  ]

  @doc "Normalize a request map into a `t/0` struct with defaults applied."
  @spec normalize(map() | t()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = request), do: {:ok, request}

  def normalize(%{} = map) do
    request = %__MODULE__{
      domain: Map.get(map, :domain) || Map.get(map, "domain"),
      resource: Map.get(map, :resource) || Map.get(map, "resource"),
      type: normalize_atom(Map.get(map, :type) || Map.get(map, "type")),
      column: normalize_atom(Map.get(map, :column) || Map.get(map, "column")),
      function: normalize_atom(Map.get(map, :function) || Map.get(map, "function")),
      bucket: normalize_atom(Map.get(map, :bucket) || Map.get(map, "bucket")),
      time_field: normalize_atom(Map.get(map, :time_field) || Map.get(map, "time_field")),
      group_by: normalize_atoms(Map.get(map, :group_by) || Map.get(map, "group_by") || []),
      percentiles: Map.get(map, :percentiles) || Map.get(map, "percentiles") || [],
      filters: normalize_filters(Map.get(map, :filters) || Map.get(map, "filters") || %{}),
      limit: Map.get(map, :limit) || Map.get(map, "limit")
    }

    {:ok, request}
  end

  def normalize(other) do
    {:error,
     AshDyan.Error.exception(
       message: "request must be a map or AshDyan.Request, got #{inspect(other)}"
     )}
  end

  # Accept both atom and string keys/values so requests coming from an HTTP
  # adapter (which carry string keys) work without manual coercion.
  defp normalize_atom(nil), do: nil
  defp normalize_atom(value) when is_atom(value), do: value
  defp normalize_atom(value) when is_binary(value), do: String.to_existing_atom(value)
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
  Validate a normalized request against the resource's `dynal` DSL whitelist.

  Returns `:ok` or `{:error, %AshDyan.Error{}}` naming the offending field.

  ## Error reasons

  The `reason` field of the returned `AshDyan.Error` is one of:

  - `:not_a_resource` / `:not_analyzable` — the `:resource` is invalid or has
    no `dynal` configuration.
  - `:unknown_type` — `:type` is not one of the four capabilities.
  - `:not_analyzable` — `:column`/`time_field` is not whitelisted for the type.
  - `:not_allowed` — `:function`/`:bucket`/`:percentiles` is not in the
    whitelist for that field, or `:filters` references a non-allowed field.
  - `:too_many` — `:group_by` exceeds `max_group_by`.
  - `:too_large` — `:limit` exceeds `max_limit`.
  - `:unknown_attribute` — `:group_by` references a non-existent attribute.
  - `:bad_type` — `:filters`/`limit` is of the wrong type.
  """
  @spec validate(t()) :: :ok | {:error, AshDyan.Error.t()}
  def validate(%__MODULE__{} = request) do
    with :ok <- validate_resource_present(request),
         :ok <- validate_type(request),
         :ok <- validate_column(request),
         :ok <- validate_function(request),
         :ok <- validate_bucket(request),
         :ok <- validate_percentiles(request),
         :ok <- validate_group_by(request),
         :ok <- validate_filters(request),
         :ok <- validate_limit(request) do
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
           message: "#{inspect(resource)} is not analyzable (no `dynal` section)"
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

  defp validate_type(%{type: type})
       when type in [:frequency, :aggregate, :time_bucket, :percentile],
       do: :ok

  defp validate_type(%{type: type}) do
    {:error,
     AshDyan.Error.exception(
       field: :type,
       reason: :unknown_type,
       message:
         "type must be one of :frequency, :aggregate, :time_bucket, :percentile, got #{inspect(type)}"
     )}
  end

  defp validate_column(%{type: :frequency, column: nil}) do
    {:error, AshDyan.Error.exception(field: :column, message: ":frequency requires a :column")}
  end

  defp validate_column(%{type: :frequency, column: column, resource: resource}) do
    if AshDyan.Info.analyzable_field(resource, column, :frequency) do
      :ok
    else
      {:error,
       AshDyan.Error.exception(
         field: :column,
         reason: :not_analyzable,
         message: "column :#{column} is not declared as analyzable for type :frequency"
       )}
    end
  end

  defp validate_column(%{type: type, column: column, resource: resource})
       when type in [:aggregate, :percentile] do
    if column do
      field = AshDyan.Info.analyzable_field(resource, column, type)

      if field do
        :ok
      else
        {:error,
         AshDyan.Error.exception(
           field: :column,
           reason: :not_analyzable,
           message: "column :#{column} is not declared as analyzable for type #{type}"
         )}
      end
    else
      {:error, AshDyan.Error.exception(field: :column, message: "#{type} requires a :column")}
    end
  end

  defp validate_column(%{type: :time_bucket, column: nil, time_field: nil}) do
    {:error,
     AshDyan.Error.exception(
       field: :time_field,
       message: ":time_bucket requires a :time_field (or a :column used as the time field)"
     )}
  end

  defp validate_column(%{type: :time_bucket} = request) do
    time_field = request.time_field || request.column

    field = AshDyan.Info.analyzable_field(request.resource, time_field, :time_bucket)

    if field do
      :ok
    else
      {:error,
       AshDyan.Error.exception(
         field: :time_field,
         reason: :not_analyzable,
         message: "time field :#{time_field} is not declared as analyzable for type :time_bucket"
       )}
    end
  end

  defp validate_column(_request), do: :ok

  defp validate_function(%{type: type, column: _column, function: function, resource: _resource})
       when type in [:aggregate, :percentile] do
    # `:percentile` does not use a function (it is driven by `:percentiles`),
    # so only `:aggregate` requires `:function` to be present.
    if type == :percentile or function do
      :ok
    else
      {:error,
       AshDyan.Error.exception(
         field: :function,
         message: "#{type} requires a :function"
       )}
    end
  end

  defp validate_function(_request), do: :ok

  defp validate_bucket(%{type: :time_bucket, bucket: bucket} = request) do
    if bucket do
      time_field = request.time_field || request.column
      field = AshDyan.Info.analyzable_field(request.resource, time_field, :time_bucket)

      allowed = if field, do: field.buckets, else: []

      if bucket in allowed do
        :ok
      else
        {:error,
         AshDyan.Error.exception(
           field: :bucket,
           reason: :not_allowed,
           message:
             "bucket :#{bucket} is not allowed for :time_bucket on :#{time_field}; allowed: #{inspect(allowed)}"
         )}
      end
    else
      {:error,
       AshDyan.Error.exception(field: :bucket, message: ":time_bucket requires a :bucket")}
    end
  end

  defp validate_bucket(_request), do: :ok

  defp validate_percentiles(%{type: :percentile, percentiles: []}) do
    {:error,
     AshDyan.Error.exception(field: :percentiles, message: ":percentile requires :percentiles")}
  end

  defp validate_percentiles(
         %{type: :percentile, column: column, percentiles: percentiles} = request
       ) do
    field = AshDyan.Info.analyzable_field(request.resource, column, :percentile)
    allowed = if field, do: field.percentiles, else: []

    invalid = Enum.reject(percentiles, &(&1 in allowed))

    if invalid == [] do
      :ok
    else
      {:error,
       AshDyan.Error.exception(
         field: :percentiles,
         reason: :not_allowed,
         message:
           "percentiles #{inspect(invalid)} are not allowed for :percentile on :#{column}; allowed: #{inspect(allowed)}"
       )}
    end
  end

  defp validate_percentiles(_request), do: :ok

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
