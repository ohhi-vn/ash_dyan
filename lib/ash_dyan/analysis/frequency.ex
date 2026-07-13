defmodule AshDyan.Analysis.Frequency do
  @moduledoc false
  @behaviour AshDyan.Analysis

  alias AshDyan.Engine.Formatter
  alias AshDyan.Error

  @impl true
  def validate(%{column: nil}) do
    {:error, Error.exception(field: :column, message: ":frequency requires a :column")}
  end

  def validate(%{column: column, resource: resource}) do
    if AshDyan.Info.analyzable_field(resource, column, :frequency) do
      :ok
    else
      {:error,
       Error.exception(
         field: :column,
         reason: :not_analyzable,
         message: "column :#{column} is not declared as analyzable for type :frequency"
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
  def recommend_chart(%{type: :frequency, series: series}) do
    if length(series) == 1, do: :pie, else: :bar
  end

  @impl true
  def supports_presentation?(_option), do: true
end
