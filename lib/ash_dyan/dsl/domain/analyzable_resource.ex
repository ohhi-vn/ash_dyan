defmodule AshDyan.Dsl.Domain.AnalyzableResource do
  @moduledoc """
  Struct describing a single `analyzable_resource` declared in the `dyan` DSL
  section of a Domain.

  This is a thin registry for resource discovery. Cross-resource joins are out
  of scope for v1.
  """

  @type t :: %__MODULE__{
          resource: module()
        }

  defstruct [
    :resource,
    :__spark_metadata__
  ]
end
