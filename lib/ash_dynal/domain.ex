defmodule AshDynal.Domain do
  @moduledoc """
  Convenience alias for the domain-level AshDynal extension.

  Use it in a domain:

      use Ash.Domain, extensions: [AshDynal.Domain]
  """
  use AshDynal.Dsl.Domain.Extension
end
