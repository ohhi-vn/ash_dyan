defmodule AshDynalTest do
  use ExUnit.Case, async: false

  alias AshDynal.Test.{Order, Seed, Shop}

  # `Ash.DataLayer.Simple` does not persist; attach the in-memory dataset to each
  # read via `set_data/2`.
  defp read(resource, query) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.DataLayer.Simple.set_data(Seed.order_rows())
    |> Ash.read!()
  end

  setup do
    :ok
  end

  describe "DSL / Info" do
    test "resource declares analyzable fields" do
      fields = AshDynal.Info.analyzable_fields(Order)
      assert length(fields) == 4
      assert AshDynal.Info.analyzable?(Order)
      assert AshDynal.Info.max_group_by(Order) == 3
      assert AshDynal.Info.allow_filters_on(Order) == [:status, :region, :inserted_at]
    end

    test "domain registers analyzable resources" do
      assert AshDynal.Domain.Info.analyzable_resources(Shop) == [Order]
    end

    test "capability check reflects the data layer" do
      assert AshDynal.supports?(Order, :frequency)
      assert AshDynal.supports?(Order, :aggregate)
      assert AshDynal.supports?(Order, :time_bucket)
      # ETS does not support percentiles in v1 (computed in memory, but the
      # capability gate intentionally reports unsupported for the Simple layer).
      refute AshDynal.supports?(Order, :percentile)
    end
  end

  describe "validation" do
    test "rejects unknown column" do
      assert {:error, %AshDynal.Error{field: :column}} =
               AshDynal.run(%{
                 resource: Order,
                 type: :frequency,
                 column: :nonexistent
               })
    end

    test "rejects disallowed function" do
      assert {:error, %AshDynal.Error{field: :function, reason: :not_allowed}} =
               AshDynal.run(%{
                 resource: Order,
                 type: :aggregate,
                 column: :total_amount,
                 function: :count
               })
    end

    test "rejects too many group_by" do
      assert {:error, %AshDynal.Error{field: :group_by, reason: :too_many}} =
               AshDynal.run(%{
                 resource: Order,
                 type: :frequency,
                 column: :status,
                 group_by: [:region, :status, :inserted_at, :id]
               })
    end

    test "rejects filter on non-allowed field" do
      assert {:error, %AshDynal.Error{field: :filters}} =
               AshDynal.run(%{
                 resource: Order,
                 type: :frequency,
                 column: :status,
                 filters: %{id: "x"}
               })
    end

    test "rejects limit over max" do
      assert {:error, %AshDynal.Error{field: :limit, reason: :too_large}} =
               AshDynal.run(%{
                 resource: Order,
                 type: :frequency,
                 column: :status,
                 limit: 5000
               })
    end
  end

  describe "frequency" do
    test "counts by column" do
      {:ok, result} = AshDynal.run(%{resource: Order, type: :frequency, column: :status}, data: Seed.order_rows())
      assert result.type == :frequency
      # 3 paid, 1 pending, 2 refunded = 6 total
      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 6
      assert "paid" in result.labels
    end

    test "counts grouped by region" do
      {:ok, result} =
        AshDynal.run(%{resource: Order, type: :frequency, column: :status, group_by: [:region]},
          data: Seed.order_rows()
        )

      assert result.type == :frequency
      # labels are status values; one series per region
      assert "paid" in result.labels
      assert Enum.any?(result.series, fn s -> s.name == "EU" end)
    end
  end

  describe "aggregate" do
    test "sums total_amount" do
      {:ok, result} =
        AshDynal.run(%{resource: Order, type: :aggregate, column: :total_amount, function: :sum},
          data: Seed.order_rows()
        )

      assert result.type == :aggregate
      [series] = result.series
      assert series.name == "sum"
      # 100 + 50 + 20 + 200 + 10 + 30 = 410
      assert List.first(series.data) == Decimal.new("410.0")
    end
  end

  describe "time_bucket" do
    test "buckets by day" do
      {:ok, result} =
        AshDynal.run(
          %{
            resource: Order,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            function: :sum,
            column: :total_amount
          },
          data: Seed.order_rows()
        )

      assert result.type == :time_bucket
      assert length(result.labels) >= 1
    end
  end

  describe "percentile" do
    test "computes percentiles in memory (ETS unsupported capability, but engine still computes)" do
      # The capability gate reports :percentile unsupported on ETS, so run/1
      # returns an error. We exercise the in-memory formatter directly instead.
      records = read(Order, Ash.Query.for_read(Order, :read))

      request = %AshDynal.Request{
        type: :percentile,
        column: :total_amount,
        percentiles: [50, 90, 99]
      }

      {:ok, result} = AshDynal.Engine.Formatter.format(request, records)
      assert result.type == :percentile
      assert length(result.series) == 1
      assert length(hd(result.series).data) == 3
    end
  end

  describe "filters" do
    test "applies allowed filters" do
      {:ok, result} =
        AshDynal.run(
          %{
            resource: Order,
            type: :frequency,
            column: :status,
            filters: %{status: :paid}
          },
          data: Seed.order_rows()
        )

      # Only paid rows counted -> 3 paid orders
      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 3
    end
  end
end
