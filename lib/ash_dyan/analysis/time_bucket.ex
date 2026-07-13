defmodule AshDyan.Analysis.TimeBucket do
  @moduledoc false
  @behaviour AshDyan.Analysis

  alias AshDyan.Engine.Formatter
  alias AshDyan.Error

  @impl true
  def validate(%{column: nil, time_field: nil}) do
    {:error,
     Error.exception(
       field: :time_field,
       message: ":time_bucket requires a :time_field (or a :column used as the time field)"
     )}
  end

  def validate(%{column: _column, time_field: _time_field, bucket: nil, resource: _resource}) do
    {:error, Error.exception(field: :bucket, message: ":time_bucket requires a :bucket")}
  end

  def validate(%{column: column, time_field: time_field, bucket: bucket, function: function, resource: resource}) do
    # The field that is bucketed on is the explicit `:time_field`, or the
    # `:column` when no `:time_field` is supplied. The `:column` is only the
    # metric being aggregated (and may be nil for a plain count).
    time_field = time_field || column
    field = AshDyan.Info.analyzable_field(resource, time_field, :time_bucket)

    with :ok <- validate_bucket(field, bucket, time_field),
         :ok <- validate_function(column, function, resource) do
      :ok
    end
  end

  defp validate_bucket(nil, _bucket, time_field) do
    {:error,
     Error.exception(
       field: :time_field,
       reason: :not_analyzable,
       message: "time field :#{time_field} is not declared as analyzable for type :time_bucket"
     )}
  end

  defp validate_bucket(field, bucket, time_field) do
    allowed = field.buckets

    if bucket in allowed do
      :ok
    else
      {:error,
       Error.exception(
         field: :bucket,
         reason: :not_allowed,
         message:
           "bucket :#{bucket} is not allowed for :time_bucket on :#{time_field}; allowed: #{inspect(allowed)}"
       )}
    end
  end

  # The time_bucket metric `function` is validated against the metric column's
  # `:aggregate` whitelist (the same whitelist that governs `:aggregate` on that
  # column), plus any runtime-registered custom aggregates. A nil function means
  # a plain row count, which is always allowed.
  defp validate_function(_column, nil, _resource), do: :ok
  defp validate_function(nil, _function, _resource), do: :ok

  defp validate_function(column, function, resource) do
    case AshDyan.Info.analyzable_field(resource, column, :aggregate) do
      nil ->
        {:error,
         Error.exception(
           field: :column,
           reason: :not_analyzable,
           message: "column :#{column} is not declared as analyzable for type :aggregate"
         )}

      %{functions: allowed} ->
        custom = Application.get_env(:ash_dyan, :custom_aggregates, %{}) |> Map.keys()

        if function in allowed or function in custom do
          :ok
        else
          {:error,
           Error.exception(
             field: :function,
             reason: :not_allowed,
             message:
               "function :#{function} is not allowed for :time_bucket on :#{column}; allowed: #{inspect(allowed)}"
           )}
        end
    end
  end

  @impl true
  def select_fields(%{column: column, time_field: time_field, group_by: group_by}) do
    effective = time_field || column
    [effective, column | group_by] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  @impl true
  def format(request, records), do: Formatter.format(request, records)

  @impl true
  def recommend_chart(%{type: :time_bucket}), do: :line

  @impl true
  def supports_presentation?(option) when option in [:sort_by, :top], do: false
  def supports_presentation?(_option), do: true
end
