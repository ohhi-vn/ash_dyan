defmodule AshDyan.Analysis.Histogram do
  @moduledoc false
  @behaviour AshDyan.Analysis

  alias AshDyan.Engine.Formatter
  alias AshDyan.Error

  @impl true
  def validate(%{column: nil}) do
    {:error, Error.exception(field: :column, message: ":histogram requires a :column")}
  end

  def validate(%{column: column, bins: bins, bin_width: bin_width, resource: resource}) do
    case validate_column(column, resource) do
      :ok -> validate_bins(bins, bin_width)
      error -> error
    end
  end

  defp validate_column(column, resource) do
    if AshDyan.Info.analyzable_field(resource, column, :histogram) do
      :ok
    else
      {:error,
       Error.exception(
         field: :column,
         reason: :not_analyzable,
         message: "column :#{column} is not declared as analyzable for type :histogram"
       )}
    end
  end

  defp validate_bins(bins, bin_width) do
    cond do
      not is_nil(bins) and not (is_integer(bins) and bins > 0) ->
        {:error,
         Error.exception(
           field: :bins,
           reason: :bad_bins,
           message: ":bins must be a positive integer, got #{inspect(bins)}"
         )}

      not is_nil(bin_width) and not (is_number(bin_width) and bin_width > 0) ->
        {:error,
         Error.exception(
           field: :bin_width,
           reason: :bad_bins,
           message: ":bin_width must be a positive number, got #{inspect(bin_width)}"
         )}

      true ->
        :ok
    end
  end

  @impl true
  def select_fields(%{column: column, group_by: group_by}) do
    Enum.uniq([column | group_by])
  end

  @impl true
  def format(request, records), do: Formatter.format(request, records)

  @impl true
  def recommend_chart(%{type: :histogram}), do: :histogram

  @impl true
  def supports_presentation?(option) when option in [:sort_by, :top], do: false
  def supports_presentation?(_option), do: true
end
