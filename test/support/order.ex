defmodule AshDyan.Test.Order do
  @moduledoc false

  use Ash.Resource,
    extensions: [AshDyan],
    data_layer: Ash.DataLayer.Simple

  attributes do
    uuid_primary_key(:id)

    attribute :status, :atom do
      constraints(one_of: [:paid, :refunded, :pending])
      default(:pending)
    end

    attribute :region, :atom do
      constraints(one_of: [:EU, :US, :APAC])
    end

    attribute(:total_amount, :decimal)
    attribute(:inserted_at, :utc_datetime)
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  dynal do
    analyzable_field(:status, type: :frequency)
    analyzable_field(:total_amount, type: :aggregate, functions: [:sum, :avg, :min, :max])
    analyzable_field(:inserted_at, type: :time_bucket, buckets: [:day, :week, :month])
    analyzable_field(:total_amount, type: :percentile, percentiles: [50, 90, 99])

    max_group_by(3)
    default_limit(100)
    max_limit(1000)
    allow_filters_on([:status, :region, :inserted_at])
  end
end
