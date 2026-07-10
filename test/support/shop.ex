defmodule AshDynal.Test.Shop do
  @moduledoc false

  use Ash.Domain, extensions: [AshDynal.Domain]

  resources do
    resource(AshDynal.Test.Order)
  end

  dynal do
    analyzable_resource(AshDynal.Test.Order)
  end
end
