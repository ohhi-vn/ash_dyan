defmodule AshDyan.Test.Shop do
  @moduledoc false

  use Ash.Domain, extensions: [AshDyan.Domain]

  resources do
    resource(AshDyan.Test.Order)

    if System.get_env("RUN_POSTGRES") == "1" do
      resource(AshDyan.Test.PostgresOrder)
    end
  end

  dyan do
    analyzable_resource(AshDyan.Test.Order)
  end
end
