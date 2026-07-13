defmodule AshDyan.Analysis.Percentile do
  @moduledoc false
  @behaviour AshDyan.Analysis

  alias AshDyan.Engine.Formatter
  alias AshDyan.Error

  @impl true
  def validate(%{column: nil}) do
    {:error, Error.exception(field: :column, message: ":percentile requires a :column")}
  end

  def validate(%{percentiles: []}) do
    {:error, Error.exception(field: :percentiles, message: ":percentile requires :percentiles")}
  end

  def validate(%{column: column, percentiles: percentiles, resource: resource}) do
    field = AshDyan.Info.analyzable_field(resource, column, :percentile)
    allowed = if field, do: field.percentiles, else: []

    invalid = Enum.reject(percentiles, &(&1 in allowed))

    if field do
      if invalid == [] do
        :ok
      else
        {:error,
         Error.exception(
           field: :percentiles,
           reason: :not_allowed,
           message:
             "percentiles #{inspect(invalid)} are not allowed for :percentile on :#{column}; allowed: #{inspect(allowed)}"
         )}
      end
    else
      {:error,
       Error.exception(
         field: :column,
         reason: :not_analyzable,
         message: "column :#{column} is not declared as analyzable for type :percentile"
       )}
    end
  end

  @impl true
  def select_fields(%{column: column, group_by: group_by}) do
    Enum.uniq([column | group_by])
  end

  @impl true
  def format(request, records), do: Formatter.format(request, records)

  @impl true
  def recommend_chart(%{type: :percentile}), do: :line

  @impl true
  def supports_presentation?(_option), do: true
end
