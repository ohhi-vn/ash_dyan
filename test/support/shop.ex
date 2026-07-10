defmodule AshDyan.Test.Shop do
  @moduledoc false

  use Ash.Domain, extensions: [AshDyan.Domain]

  resources do
    resource(AshDyan.Test.Order)
  end

  dynal do
    analyzable_resource(AshDyan.Test.Order)
  end
end
