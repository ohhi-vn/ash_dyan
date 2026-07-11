defmodule AshDyan.Test.Plain do
  @moduledoc false

  # A valid Ash resource that intentionally has NO `dyan` section, used to
  # exercise the `:not_analyzable` validation path.
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Simple

  attributes do
    uuid_primary_key(:id)
    attribute(:status, :atom)
    attribute(:score, :integer)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end
end
