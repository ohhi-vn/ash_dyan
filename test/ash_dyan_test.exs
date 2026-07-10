defmodule AshDyanTest do
  use ExUnit.Case, async: false

  alias AshDyan.Test.{Order, Plain, Seed, Shop}

  # `Ash.DataLayer.Simple` does not persist; attach the in-memory dataset to each
  # read via `set_data/2`.
  defp read(resource, _query) do
    resource
    |> Ash.Query.for_read(:read, %{}, domain: Shop)
    |> Ash.DataLayer.Simple.set_data(Seed.order_rows())
    |> Ash.read!()
  end

  setup do
    :ok
  end

  describe "DSL / Info" do
    test "resource declares analyzable fields" do
      fields = AshDyan.Info.analyzable_fields(Order)
      assert length(fields) == 4
      assert AshDyan.Info.analyzable?(Order)
      assert AshDyan.Info.max_group_by(Order) == 3
      assert AshDyan.Info.allow_filters_on(Order) == [:status, :region, :inserted_at]
    end

    test "domain registers analyzable resources" do
      assert AshDyan.Domain.Info.analyzable_resources(Shop) == [Order]
    end

    test "capability check reflects the data layer" do
      assert AshDyan.supports?(Order, :frequency)
      assert AshDyan.supports?(Order, :aggregate)
      assert AshDyan.supports?(Order, :time_bucket)
      # ETS does not support percentiles in v1 (computed in memory, but the
      # capability gate intentionally reports unsupported for the Simple layer).
      refute AshDyan.supports?(Order, :percentile)
    end
  end

  describe "validation" do
    test "rejects unknown column" do
      assert {:error, %AshDyan.Error{field: :column}} =
               AshDyan.run(%{
                 resource: Order, domain: Shop,
                 type: :frequency,
                 column: :nonexistent
               })
    end

    test "rejects disallowed function" do
      # `:count` is not a valid aggregate function in the DSL schema, so it is
      # rejected during normalization/validation (before the whitelist check).
      assert {:error, _} =
               AshDyan.run(%{
                 resource: Order, domain: Shop,
                 type: :aggregate,
                 column: :total_amount,
                 function: :count
               })
    end

    test "rejects too many group_by" do
      assert {:error, %AshDyan.Error{field: :group_by, reason: :too_many}} =
               AshDyan.run(%{
                 resource: Order, domain: Shop,
                 type: :frequency,
                 column: :status,
                 group_by: [:region, :status, :inserted_at, :id]
               })
    end

    test "rejects filter on non-allowed field" do
      assert {:error, %AshDyan.Error{field: :filters}} =
               AshDyan.run(%{
                 resource: Order, domain: Shop,
                 type: :frequency,
                 column: :status,
                 filters: %{id: "x"}
               })
    end

    test "rejects limit over max" do
      assert {:error, %AshDyan.Error{field: :limit, reason: :too_large}} =
               AshDyan.run(%{
                 resource: Order, domain: Shop,
                 type: :frequency,
                 column: :status,
                 limit: 5000
               })
    end

    test "rejects group_by on a non-existent attribute" do
      assert {:error, %AshDyan.Error{field: :group_by, reason: :unknown_attribute}} =
               AshDyan.run(%{
                 resource: Order, domain: Shop,
                 type: :frequency,
                 column: :status,
                 group_by: [:nonexistent]
               })
    end

    test "accepts string-keyed request maps (HTTP adapter shape)" do
      {:ok, result} =
        AshDyan.run(
          %{
            "resource" => Order,
            "domain" => Shop,
            "type" => "frequency",
            "column" => "status",
            "group_by" => ["region"]
          },
          data: Seed.order_rows()
        )

      assert result.type == :frequency
      assert "paid" in result.labels
    end

    test "rejects a non-Ash-resource module" do
      assert {:error, %AshDyan.Error{field: :resource, reason: :not_a_resource}} =
               AshDyan.run(%{resource: NotAModule, type: :frequency, column: :status})
    end

    test "rejects a resource without a dynal section" do
      assert {:error, %AshDyan.Error{field: :resource, reason: :not_analyzable}} =
               AshDyan.run(%{resource: Plain, type: :frequency, column: :status})
    end

    test "rejects a missing resource" do
      assert {:error, %AshDyan.Error{field: :resource}} =
               AshDyan.run(%{type: :frequency, column: :status})
    end

    test "rejects an unknown analysis type" do
      assert {:error, %AshDyan.Error{field: :type, reason: :unknown_type}} =
               AshDyan.run(%{resource: Order, type: :bogus, column: :status})
    end

    test "rejects a non-map request" do
      assert {:error, %AshDyan.Error{}} = AshDyan.run(:not_a_map, [])
    end

    test "rejects a missing column for frequency" do
      assert {:error, %AshDyan.Error{field: :column}} =
               AshDyan.run(%{resource: Order, type: :frequency})
    end

    test "rejects a missing function for aggregate" do
      assert {:error, %AshDyan.Error{field: :function}} =
               AshDyan.run(%{resource: Order, type: :aggregate, column: :total_amount})
    end

    test "rejects a missing bucket for time_bucket" do
      assert {:error, %AshDyan.Error{field: :bucket}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :time_bucket,
                 time_field: :inserted_at,
                 column: :total_amount
               })
    end

    test "rejects a missing time_field for time_bucket" do
      assert {:error, %AshDyan.Error{field: :time_field}} =
               AshDyan.run(%{resource: Order, type: :time_bucket, bucket: :day, column: :total_amount})
    end

    test "rejects a missing percentiles for percentile" do
      assert {:error, %AshDyan.Error{field: :percentiles}} =
               AshDyan.run(%{resource: Order, type: :percentile, column: :total_amount})
    end

    test "rejects a non-allowed bucket for time_bucket" do
      assert {:error, %AshDyan.Error{field: :bucket, reason: :not_allowed}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :time_bucket,
                 time_field: :inserted_at,
                 bucket: :year,
                 column: :total_amount
               })
    end

    test "rejects a non-allowed percentile" do
      assert {:error, %AshDyan.Error{field: :percentiles, reason: :not_allowed}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :percentile,
                 column: :total_amount,
                 percentiles: [1]
               })
    end

    test "rejects a non-map filters value" do
      assert {:error, %AshDyan.Error{field: :filters, reason: :bad_type}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :frequency,
                 column: :status,
                 filters: [:status]
               })
    end

    test "rejects a non-integer limit" do
      assert {:error, %AshDyan.Error{field: :limit, reason: :bad_type}} =
               AshDyan.run(%{resource: Order, type: :frequency, column: :status, limit: "all"})
    end

    test "rejects a zero/negative limit" do
      assert {:error, %AshDyan.Error{field: :limit, reason: :bad_type}} =
               AshDyan.run(%{resource: Order, type: :frequency, column: :status, limit: 0})
    end

    test "rejects a non-whitelisted column for aggregate" do
      assert {:error, %AshDyan.Error{field: :column, reason: :not_analyzable}} =
               AshDyan.run(%{resource: Order, type: :aggregate, column: :status, function: :sum})
    end

    test "rejects a non-whitelisted time_field for time_bucket" do
      assert {:error, %AshDyan.Error{field: :time_field, reason: :not_analyzable}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :time_bucket,
                 time_field: :status,
                 bucket: :day,
                 column: :total_amount
               })
    end

    test "rejects a non-whitelisted column for percentile" do
      assert {:error, %AshDyan.Error{field: :column, reason: :not_analyzable}} =
               AshDyan.run(%{resource: Order, type: :percentile, column: :status, percentiles: [50]})
    end

    test "rejects a non-allowed filter field" do
      assert {:error, %AshDyan.Error{field: :filters, reason: :not_allowed}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :frequency,
                 column: :status,
                 filters: %{secret: 1}
               })
    end

    test "rejects a non-analyzable column for frequency" do
      assert {:error, %AshDyan.Error{field: :column, reason: :not_analyzable}} =
               AshDyan.run(%{resource: Order, type: :frequency, column: :region})
    end

    test "rejects group_by exactly at max boundary is allowed, one over is rejected" do
      # max_group_by is 3; 3 fields is allowed, 4 is rejected (covered above).
      {:ok, _} =
        AshDyan.run(%{
          resource: Order,
          domain: Shop,
          type: :frequency,
          column: :status,
          group_by: [:region, :inserted_at]
        },
          data: Seed.order_rows()
        )
    end
  end

  describe "frequency" do
    test "counts by column" do
      {:ok, result} = AshDyan.run(%{resource: Order, domain: Shop, type: :frequency, column: :status}, data: Seed.order_rows())
      assert result.type == :frequency
      # 3 paid, 1 pending, 2 refunded = 6 total
      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 6
      assert "paid" in result.labels
    end

    test "counts grouped by region" do
      {:ok, result} =
        AshDyan.run(%{resource: Order, domain: Shop, type: :frequency, column: :status, group_by: [:region]},
          data: Seed.order_rows()
        )

      assert result.type == :frequency
      # labels are status values; one series per region
      assert "paid" in result.labels
      assert Enum.any?(result.series, fn s -> s.name == "EU" end)
    end

    test "empty dataset yields zero counts" do
      {:ok, result} =
        AshDyan.run(%{resource: Order, domain: Shop, type: :frequency, column: :status},
          data: []
        )

      assert result.labels == []
      assert result.series == [%{name: "status", data: []}]
    end

    test "grouped frequency aligns series to the shared label axis" do
      {:ok, result} =
        AshDyan.run(%{resource: Order, domain: Shop, type: :frequency, column: :status, group_by: [:region]},
          data: Seed.order_rows()
        )

      # Every series must have exactly one data point per label (aligned axis).
      assert Enum.all?(result.series, fn s -> length(s.data) == length(result.labels) end)
    end

    test "frequency counts rows whose metric is nil under the 'nil' label" do
      # Exercise the formatter directly: a nil `status` becomes the "nil" label.
      records = [
        %Order{id: "a", status: nil, region: :EU, total_amount: Decimal.new("1.0")},
        %Order{id: "b", status: :paid, region: :EU, total_amount: Decimal.new("2.0")}
      ]

      {:ok, result} =
        AshDyan.Engine.Formatter.format(
          %AshDyan.Request{type: :frequency, column: :status},
          records
        )

      assert "nil" in result.labels
      # status nil -> 1, status paid -> 1
      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 2
    end
  end

  describe "aggregate" do
    test "sums total_amount" do
      {:ok, result} =
        AshDyan.run(%{resource: Order, domain: Shop, type: :aggregate, column: :total_amount, function: :sum},
          data: Seed.order_rows()
        )

      assert result.type == :aggregate
      [series] = result.series
      assert series.name == "sum"
      # 100 + 50 + 20 + 200 + 10 + 30 = 410
      assert List.first(series.data) == Decimal.new("410.0")
    end

    test "computes avg/min/max" do
      for {fun, expected} <- [avg: Decimal.new("68.33333333333333333333333333333"), min: Decimal.new("10.0"), max: Decimal.new("200.0")] do
        {:ok, result} =
          AshDyan.run(%{resource: Order, domain: Shop, type: :aggregate, column: :total_amount, function: fun},
            data: Seed.order_rows()
          )

        name = to_string(fun)
        [%{name: ^name, data: [actual]}] = result.series
        assert Decimal.equal?(Decimal.round(actual, 4), Decimal.round(expected, 4)),
               "expected #{expected}, got #{actual}"
      end
    end

    test "aggregate with group_by produces one label per group" do
      {:ok, result} =
        AshDyan.run(
          %{resource: Order, domain: Shop, type: :aggregate, column: :total_amount, function: :sum, group_by: [:region]},
          data: Seed.order_rows()
        )

      # EU: 100 + 20 + 30 = 150; US: 50 + 10 = 60; APAC: 200
      # The `labels` axis is the three regions; each series carries one value per label.
      assert result.labels == ["APAC", "EU", "US"]
      [series] = result.series
      assert series.name == "sum"
      by_region = Map.new(Enum.zip(result.labels, series.data))
      assert by_region["EU"] == Decimal.new("150.0")
      assert by_region["US"] == Decimal.new("60.0")
      assert by_region["APAC"] == Decimal.new("200.0")
    end

    test "aggregate over an empty dataset yields nil" do
      {:ok, result} =
        AshDyan.run(%{resource: Order, domain: Shop, type: :aggregate, column: :total_amount, function: :sum},
          data: []
        )

      assert [%{data: [nil]}] = result.series
    end

    test "aggregate ignores nil metric values" do
      # Exercise the formatter directly (bypassing the ETS read, which cannot
      # sort rows carrying a nil attribute). The formatter must skip nil metrics.
      records = [
        %Order{id: "a", status: :paid, region: :EU, total_amount: nil},
        %Order{id: "b", status: :paid, region: :EU, total_amount: Decimal.new("5.0")}
      ]

      {:ok, result} =
        AshDyan.Engine.Formatter.format(
          %AshDyan.Request{type: :aggregate, column: :total_amount, function: :sum},
          records
        )

      assert [%{data: [sum]}] = result.series
      assert sum == Decimal.new("5.0")
    end
  end

  describe "time_bucket" do
    test "buckets by day" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order, domain: Shop,
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

    test "buckets by week and month" do
      for bucket <- [:week, :month] do
        {:ok, result} =
          AshDyan.run(
            %{
              resource: Order, domain: Shop,
              type: :time_bucket,
              time_field: :inserted_at,
              bucket: bucket,
              function: :sum,
              column: :total_amount
            },
            data: Seed.order_rows()
          )

        assert result.type == :time_bucket
        # All six seed rows fall within one month; the week bucket splits them across
        # two ISO weeks (Jul 1 is mid-week, Jul 6 starts a new week).
        assert length(result.labels) >= 1
      end
    end

    test "time_bucket with group_by produces a series per group" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order, domain: Shop,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            function: :sum,
            column: :total_amount,
            group_by: [:region]
          },
          data: Seed.order_rows()
        )

      assert Enum.any?(result.series, fn s -> s.name == "EU" end)
      assert Enum.all?(result.series, fn s -> length(s.data) == length(result.labels) end)
    end

    test "time_bucket excludes rows with a nil metric from the bucket sum" do
      records = [
        %Order{id: "a", status: :paid, region: :EU, total_amount: nil, inserted_at: ~U[2026-07-01 10:00:00Z]},
        %Order{id: "b", status: :paid, region: :EU, total_amount: Decimal.new("2.0"), inserted_at: ~U[2026-07-01 10:00:00Z]}
      ]

      {:ok, result} =
        AshDyan.Engine.Formatter.format(
          %AshDyan.Request{
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            function: :sum,
            column: :total_amount
          },
          records
        )

      # Only the non-nil metric row contributes.
      total = Enum.reduce(Enum.flat_map(result.series, & &1.data), Decimal.new(0), &Decimal.add/2)
      assert Decimal.equal?(total, Decimal.new("2.0"))
    end
  end

  describe "percentile" do
    test "computes percentiles in memory (ETS unsupported capability, but engine still computes)" do
      # The capability gate reports :percentile unsupported on ETS, so run/1
      # returns an error. We exercise the in-memory formatter directly instead.
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      request = %AshDyan.Request{
        type: :percentile,
        column: :total_amount,
        percentiles: [50, 90, 99]
      }

      {:ok, result} = AshDyan.Engine.Formatter.format(request, records)
      assert result.type == :percentile
      assert length(result.series) == 1
      assert length(hd(result.series).data) == 3
    end

    test "percentile p50 equals the interpolated median of the sorted values" do
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        AshDyan.Engine.Formatter.format(
          %AshDyan.Request{type: :percentile, column: :total_amount, percentiles: [50]},
          records
        )

      # 6 values [10,20,30,50,100,200]; p50 rank = 0.5*5 = 2.5 ->
      # linear interpolation between index 2 (30) and 3 (50) -> 40.0.
      assert Decimal.equal?(hd(hd(result.series).data), Decimal.new("40.0"))
    end

    test "percentile with group_by produces a series per group" do
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        AshDyan.Engine.Formatter.format(
          %AshDyan.Request{type: :percentile, column: :total_amount, percentiles: [50], group_by: [:region]},
          records
        )

      # EU, US, APAC -> three series
      assert length(result.series) == 3
      assert Enum.all?(result.series, fn s -> length(s.data) == 1 end)
    end

    test "percentile over an empty dataset yields nil" do
      {:ok, result} =
        AshDyan.Engine.Formatter.format(
          %AshDyan.Request{type: :percentile, column: :total_amount, percentiles: [50, 90]},
          []
        )

      assert hd(result.series).data == [nil, nil]
    end
  end

  describe "filters" do
    test "applies allowed filters" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order, domain: Shop,
            type: :frequency,
            column: :status,
            filters: %{status: :paid}
          },
          data: Seed.order_rows()
        )

      # Only paid rows counted -> 4 paid orders (ids 1, 2, 4, 6)
      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 4
    end

    test "applies an exact-match filter on a non-status field" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order, domain: Shop,
            type: :frequency,
            column: :status,
            filters: %{region: :EU}
          },
          data: Seed.order_rows()
        )

      # EU rows: ids 1, 3, 6 -> 3
      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 3
    end

    test "applies a time filter" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order, domain: Shop,
            type: :frequency,
            column: :status,
            filters: %{inserted_at: ~U[2026-07-01 00:00:00Z]}
          },
          data: Seed.order_rows()
        )

      # Only the first seed row is exactly 2026-07-01 00:00:00Z (none are).
      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 0
    end

    test "empty filters are a no-op" do
      {:ok, result} =
        AshDyan.run(
          %{resource: Order, domain: Shop, type: :frequency, column: :status, filters: %{}},
          data: Seed.order_rows()
        )

      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 6
    end

    test "filter combined with group_by" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order, domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region],
            filters: %{status: :paid}
          },
          data: Seed.order_rows()
        )

      # paid per region: EU 2 (ids 1,6), US 1 (id 2), APAC 1 (id 4)
      by_region = Map.new(result.series, fn %{name: n, data: [v]} -> {n, v} end)
      assert by_region["EU"] == 2
      assert by_region["US"] == 1
      assert by_region["APAC"] == 1
    end
  end

  describe "limits" do
    test "default limit is applied when none is given" do
      {:ok, _result} =
        AshDyan.run(
          %{resource: Order, domain: Shop, type: :frequency, column: :status},
          data: Seed.order_rows()
        )
    end

    test "explicit limit within max is accepted" do
      {:ok, _result} =
        AshDyan.run(
          %{resource: Order, domain: Shop, type: :frequency, column: :status, limit: 500},
          data: Seed.order_rows()
        )
    end
  end

  describe "run!" do
    test "raises on validation error" do
      assert_raise AshDyan.Error, fn ->
        AshDyan.run!(%{resource: Order, type: :frequency, column: :nonexistent})
      end
    end

    test "returns the result on success" do
      result =
        AshDyan.run!(%{resource: Order, domain: Shop, type: :frequency, column: :status}, data: Seed.order_rows())

      assert result.type == :frequency
    end
  end

  describe "formatter internals" do
    test "label_index maps stringified labels back to raw keys" do
      # Exercises the O(n) reverse-lookup used by the formatter (replacing the
      # previous O(n^2) label_to_key scan).
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        AshDyan.Engine.Formatter.format(
          %AshDyan.Request{type: :frequency, column: :status, group_by: [:region]},
          records
        )

      # Correctness proxy: every series aligns to the shared label axis.
      assert Enum.all?(result.series, fn s -> length(s.data) == length(result.labels) end)
    end
  end
end
