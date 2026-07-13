defmodule AshDyan.Analysis.Aggregate do
  @moduledoc false
  @behaviour AshDyan.Analysis

  alias AshDyan.Engine.Formatter
  alias AshDyan.Error

  @impl true
  def validate(%{column: nil}) do
    {:error, Error.exception(field: :column, message: ":aggregate requires a :column")}
  end

  def validate(%{column: _column, function: nil, resource: _resource}) do
    {:error, Error.exception(field: :function, message: ":aggregate requires a :function")}
  end

  def validate(%{column: column, function: function, resource: resource}) do
    case validate_column(column, resource) do
      :ok -> validate_function(column, function, resource)
      error -> error
    end
  end

  defp validate_column(column, resource) do
    if AshDyan.Info.analyzable_field(resource, column, :aggregate) do
      :ok
    else
      {:error,
       Error.exception(
         field: :column,
         reason: :not_analyzable,
         message: "column :#{column} is not declared as analyzable for type :aggregate"
       )}
    end
  end

  defp validate_function(column, function, resource) do
    allowed =
      case AshDyan.Info.analyzable_field(resource, column, :aggregate) do
        %{functions: fns} -> fns
        nil -> []
      end

    # Runtime-registered custom aggregates (config :ash_dyan, :custom_aggregates)
    # are permitted even if not declared in the DSL whitelist.
    custom = Application.get_env(:ash_dyan, :custom_aggregates, %{}) |> Map.keys()

    if function in allowed or function in custom do
      :ok
    else
      {:error,
       AshDyan.Error.exception(
         field: :function,
         reason: :not_allowed,
         message:
           "function :#{function} is not allowed for :aggregate on :#{column}; allowed: #{inspect(allowed)}"
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
  def recommend_chart(%{type: :aggregate, series: series}) do
    if length(series) == 1, do: :pie, else: :bar
  end

  @impl true
  def supports_presentation?(_option), do: true
end
