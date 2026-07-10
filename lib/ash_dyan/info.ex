defmodule AshDyan.Info do
  @moduledoc """
  Introspection helpers for the `dynal` DSL configuration of a resource.

  These read back the whitelist declared in the `dynal do ... end` section so the
  engine can validate runtime requests against it.
  """

  alias AshDyan.Dsl.AnalyzableField

  @doc """
  Returns the list of `AshDyan.Dsl.AnalyzableField` entities for a resource.

  Reads the normalized, persisted view produced by the `SetDefaults`
  transformer at compile time for fast runtime access.
  """
  @spec analyzable_fields(module()) :: [AnalyzableField.t()]
  def analyzable_fields(resource) do
    case Spark.Dsl.Extension.get_persisted(resource, :ash_dyan_fields) do
      nil -> Spark.Dsl.Extension.get_entities(resource, [:dynal])
      fields -> Enum.map(fields, &struct(AnalyzableField, &1))
    end
  end

  @doc "Returns the `AnalyzableField` for a given name and type, or `nil`."
  @spec analyzable_field(module(), atom(), :frequency | :aggregate | :time_bucket | :percentile) ::
          AnalyzableField.t() | nil
  def analyzable_field(resource, name, type) do
    Enum.find(analyzable_fields(resource), fn field ->
      field.name == name and field.type == type
    end)
  end

  @doc "Returns the maximum number of group_by fields allowed."
  @spec max_group_by(module()) :: pos_integer()
  def max_group_by(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:dynal], :max_group_by, 3)
  end

  @doc "Returns the default row limit."
  @spec default_limit(module()) :: pos_integer()
  def default_limit(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:dynal], :default_limit, 100)
  end

  @doc "Returns the maximum row limit (hard cap)."
  @spec max_limit(module()) :: pos_integer()
  def max_limit(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:dynal], :max_limit, 1000)
  end

  @doc "Returns the configured per-request query timeout (ms)."
  @spec query_timeout(module()) :: pos_integer()
  def query_timeout(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:dynal], :query_timeout, 15_000)
  end

  @doc "Returns the list of attributes a runtime request may filter on."
  @spec allow_filters_on(module()) :: [atom()]
  def allow_filters_on(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:dynal], :allow_filters_on, [])
  end

  @doc "Returns true if the resource declares any analyzable fields at all."
  @spec analyzable?(module()) :: boolean()
  def analyzable?(resource) do
    analyzable_fields(resource) != []
  end
end
