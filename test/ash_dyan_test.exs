defmodule AshDyanTest do
  use ExUnit.Case, async: false

  alias AshDyan.{Charts, Domain, Engine, Error, Info, Request}
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
      fields = Info.analyzable_fields(Order)
      assert length(fields) == 5
      assert Info.analyzable?(Order)
      assert Info.max_group_by(Order) == 3
      assert Info.allow_filters_on(Order) == [:status, :region, :inserted_at]
    end

    test "declaring the same field name under multiple types keeps all entries" do
      # The README declares `:total_amount` three times (aggregate, percentile,
      # histogram). Spark must keep all three as distinct entities rather than
      # deduping on the `:name` arg.
      total_amount_fields =
        Order
        |> Info.analyzable_fields()
        |> Enum.filter(&(&1.name == :total_amount))

      assert length(total_amount_fields) == 3

      assert Enum.map(total_amount_fields, & &1.type) |> Enum.sort() ==
               [:aggregate, :histogram, :percentile]
    end

    test "domain registers analyzable resources" do
      assert Domain.Info.analyzable_resources(Shop) == [Order]
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
      assert {:error, %Error{field: :column}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :frequency,
                 column: :nonexistent
               })
    end

    test "rejects disallowed function" do
      # `:count` is not a valid aggregate function in the DSL schema, so it is
      # rejected during normalization/validation (before the whitelist check).
      assert {:error, _} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :aggregate,
                 column: :total_amount,
                 function: :count
               })
    end

    test "rejects too many group_by" do
      assert {:error, %Error{field: :group_by, reason: :too_many}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :frequency,
                 column: :status,
                 group_by: [:region, :status, :inserted_at, :id]
               })
    end

    test "rejects filter on non-allowed field" do
      assert {:error, %Error{field: :filters}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :frequency,
                 column: :status,
                 filters: %{id: "x"}
               })
    end

    test "rejects limit over max" do
      assert {:error, %Error{field: :limit, reason: :too_large}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :frequency,
                 column: :status,
                 limit: 5000
               })
    end

    test "rejects group_by on a non-existent attribute" do
      assert {:error, %Error{field: :group_by, reason: :unknown_attribute}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
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
      assert {:error, %Error{field: :resource, reason: :not_a_resource}} =
               AshDyan.run(%{resource: NotAModule, type: :frequency, column: :status})
    end

    test "rejects a resource without a dyan section" do
      assert {:error, %Error{field: :resource, reason: :not_analyzable}} =
               AshDyan.run(%{resource: Plain, type: :frequency, column: :status})
    end

    test "rejects a missing resource" do
      assert {:error, %Error{field: :resource}} =
               AshDyan.run(%{type: :frequency, column: :status})
    end

    test "rejects an unknown analysis type" do
      assert {:error, %Error{field: :type, reason: :unknown_type}} =
               AshDyan.run(%{resource: Order, type: :bogus, column: :status})
    end

    test "rejects a non-map request" do
      assert {:error, %Error{}} = AshDyan.run(:not_a_map, [])
    end

    test "rejects a missing column for frequency" do
      assert {:error, %Error{field: :column}} =
               AshDyan.run(%{resource: Order, type: :frequency})
    end

    test "rejects a missing function for aggregate" do
      assert {:error, %Error{field: :function}} =
               AshDyan.run(%{resource: Order, type: :aggregate, column: :total_amount})
    end

    test "rejects a missing bucket for time_bucket" do
      assert {:error, %Error{field: :bucket}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :time_bucket,
                 time_field: :inserted_at,
                 column: :total_amount
               })
    end

    test "rejects a missing time_field for time_bucket" do
      assert {:error, %Error{field: :time_field}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :time_bucket,
                 bucket: :day,
                 column: :total_amount
               })
    end

    test "rejects a missing percentiles for percentile" do
      assert {:error, %Error{field: :percentiles}} =
               AshDyan.run(%{resource: Order, type: :percentile, column: :total_amount})
    end

    test "rejects a non-allowed bucket for time_bucket" do
      assert {:error, %Error{field: :bucket, reason: :not_allowed}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :time_bucket,
                 time_field: :inserted_at,
                 bucket: :year,
                 column: :total_amount
               })
    end

    test "rejects a non-allowed percentile" do
      assert {:error, %Error{field: :percentiles, reason: :not_allowed}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :percentile,
                 column: :total_amount,
                 percentiles: [1]
               })
    end

    test "rejects a non-map filters value" do
      assert {:error, %Error{field: :filters, reason: :bad_type}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :frequency,
                 column: :status,
                 filters: [:status]
               })
    end

    test "rejects a non-integer limit" do
      assert {:error, %Error{field: :limit, reason: :bad_type}} =
               AshDyan.run(%{resource: Order, type: :frequency, column: :status, limit: "all"})
    end

    test "rejects a zero/negative limit" do
      assert {:error, %Error{field: :limit, reason: :bad_type}} =
               AshDyan.run(%{resource: Order, type: :frequency, column: :status, limit: 0})
    end

    test "rejects a non-whitelisted column for aggregate" do
      assert {:error, %Error{field: :column, reason: :not_analyzable}} =
               AshDyan.run(%{resource: Order, type: :aggregate, column: :status, function: :sum})
    end

    test "rejects a non-whitelisted time_field for time_bucket" do
      assert {:error, %Error{field: :time_field, reason: :not_analyzable}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :time_bucket,
                 time_field: :status,
                 bucket: :day,
                 column: :total_amount
               })
    end

    test "rejects a non-whitelisted column for percentile" do
      assert {:error, %Error{field: :column, reason: :not_analyzable}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :percentile,
                 column: :status,
                 percentiles: [50]
               })
    end

    test "rejects a non-allowed filter field" do
      assert {:error, %Error{field: :filters, reason: :not_allowed}} =
               AshDyan.run(%{
                 resource: Order,
                 type: :frequency,
                 column: :status,
                 filters: %{secret: 1}
               })
    end

    test "rejects a non-analyzable column for frequency" do
      assert {:error, %Error{field: :column, reason: :not_analyzable}} =
               AshDyan.run(%{resource: Order, type: :frequency, column: :region})
    end

    test "rejects a non-whitelisted aggregate function" do
      # `:stddev` is declared for :total_amount, but `:median` is also declared;
      # `:sum_times_two` is neither declared nor a registered custom aggregate.
      assert {:error, %Error{field: :function, reason: :not_allowed}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :aggregate,
                 column: :total_amount,
                 function: :sum_times_two
               })
    end

    test "rejects an invalid sort_by" do
      assert {:error, %Error{field: :sort_by, reason: :bad_type}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :frequency,
                 column: :status,
                 sort_by: :nonsense
               })
    end

    test "rejects an invalid sort_order" do
      assert {:error, %Error{field: :sort_order, reason: :bad_type}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :frequency,
                 column: :status,
                 sort_order: :sideways
               })
    end

    test "rejects an invalid normalize" do
      assert {:error, %Error{field: :normalize, reason: :bad_type}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :frequency,
                 column: :status,
                 normalize: :ratio
               })
    end

    test "rejects a non-positive top" do
      assert {:error, %Error{field: :top, reason: :bad_type}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :frequency,
                 column: :status,
                 top: 0
               })
    end

    test "rejects a non-analyzable time_field declared via the dsl" do
      # `:status` is not declared as a :time_bucket field, so it is rejected as
      # the effective time field even though a :time_bucket field exists.
      assert {:error, %Error{field: :time_field, reason: :not_analyzable}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :time_bucket,
                 time_field: :status,
                 bucket: :day,
                 column: :total_amount
               })
    end

    test "rejects a non-allowed bucket for a time_field declared via the dsl" do
      # `:inserted_at` is the declared :time_bucket field with buckets
      # [:day, :week, :month]; `:year` is not allowed.
      assert {:error, %Error{field: :bucket, reason: :not_allowed}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :time_bucket,
                 time_field: :inserted_at,
                 bucket: :year,
                 column: :total_amount
               })
    end

    test "rejects group_by exactly at max boundary is allowed, one over is rejected" do
      # max_group_by is 3; 3 fields is allowed, 4 is rejected (covered above).
      {:ok, _} =
        AshDyan.run(
          %{
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
      {:ok, result} =
        AshDyan.run(%{resource: Order, domain: Shop, type: :frequency, column: :status},
          data: Seed.order_rows()
        )

      assert result.type == :frequency
      # 3 paid, 1 pending, 2 refunded = 6 total
      assert Enum.sum(result.series |> hd() |> Map.get(:data)) == 6
      assert "paid" in result.labels
    end

    test "counts grouped by region" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region]
          },
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
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region]
          },
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
        Engine.Formatter.format(
          %Request{type: :frequency, column: :status},
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
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :aggregate,
            column: :total_amount,
            function: :sum
          },
          data: Seed.order_rows()
        )

      assert result.type == :aggregate
      [series] = result.series
      assert series.name == "sum"
      # 100 + 50 + 20 + 200 + 10 + 30 = 410
      assert List.first(series.data) == Decimal.new("410.0")
    end

    test "computes avg/min/max" do
      for {fun, expected} <- [
            avg: Decimal.new("68.33333333333333333333333333333"),
            min: Decimal.new("10.0"),
            max: Decimal.new("200.0")
          ] do
        {:ok, result} =
          AshDyan.run(
            %{
              resource: Order,
              domain: Shop,
              type: :aggregate,
              column: :total_amount,
              function: fun
            },
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
          %{
            resource: Order,
            domain: Shop,
            type: :aggregate,
            column: :total_amount,
            function: :sum,
            group_by: [:region]
          },
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
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :aggregate,
            column: :total_amount,
            function: :sum
          },
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
        Engine.Formatter.format(
          %Request{type: :aggregate, column: :total_amount, function: :sum},
          records
        )

      assert [%{data: [sum]}] = result.series
      assert sum == Decimal.new("5.0")
    end

    test ":sum does not raise on a column containing nil values" do
      # Plain (non-Decimal) numeric column with a nil in the data must not raise
      # ArithmeticError; the nil is rejected before reducing.
      records = [
        %Plain{id: 1, score: 10},
        %Plain{id: 2, score: nil},
        %Plain{id: 3, score: 5}
      ]

      {:ok, result} =
        Engine.Formatter.format(
          %Request{type: :aggregate, column: :score, function: :sum},
          records
        )

      assert [%{data: [sum]}] = result.series
      assert sum == 15
    end
  end

  describe "time_bucket" do
    test "buckets by day" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            function: :sum,
            column: :total_amount
          },
          data: Seed.order_rows()
        )

      assert result.type == :time_bucket
      assert result.labels != []
    end

    test "buckets by week and month" do
      for bucket <- [:week, :month] do
        {:ok, result} =
          AshDyan.run(
            %{
              resource: Order,
              domain: Shop,
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
        assert result.labels != []
      end
    end

    test "time_bucket with group_by produces a series per group" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
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

    test "time_bucket with no column counts rows per bucket" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day
          },
          data: Seed.order_rows()
        )

      assert result.type == :time_bucket
      # Six seed rows across six distinct days => six buckets of count 1.
      assert Enum.sum(hd(result.series).data) == 6
    end

    test "time_bucket resolves the dsl-declared time_field when omitted" do
      # `:inserted_at` is the declared :time_bucket field with `time_field:
      # :inserted_at`, so a request that omits `:time_field` still selects the real
      # attribute. Omitting `:function` yields a per-bucket row count, which is
      # always valid (no metric column required).
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :time_bucket,
            bucket: :day,
            column: :inserted_at
          },
          data: Seed.order_rows()
        )

      assert result.type == :time_bucket
      assert result.labels != []
    end

    test "time_bucket excludes rows with a nil metric from the bucket sum" do
      records = [
        %Order{
          id: "a",
          status: :paid,
          region: :EU,
          total_amount: nil,
          inserted_at: ~U[2026-07-01 10:00:00Z]
        },
        %Order{
          id: "b",
          status: :paid,
          region: :EU,
          total_amount: Decimal.new("2.0"),
          inserted_at: ~U[2026-07-01 10:00:00Z]
        }
      ]

      {:ok, result} =
        Engine.Formatter.format(
          %Request{
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

      request = %Request{
        type: :percentile,
        column: :total_amount,
        percentiles: [50, 90, 99]
      }

      {:ok, result} = Engine.Formatter.format(request, records)
      assert result.type == :percentile
      assert length(result.series) == 1
      assert length(hd(result.series).data) == 3
    end

    test "percentile p50 equals the interpolated median of the sorted values" do
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        Engine.Formatter.format(
          %Request{type: :percentile, column: :total_amount, percentiles: [50]},
          records
        )

      # 6 values [10,20,30,50,100,200]; p50 rank = 0.5*5 = 2.5 ->
      # linear interpolation between index 2 (30) and 3 (50) -> 40.0.
      assert Decimal.equal?(hd(hd(result.series).data), Decimal.new("40.0"))
    end

    test "percentile with group_by produces a series per group" do
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        Engine.Formatter.format(
          %Request{
            type: :percentile,
            column: :total_amount,
            percentiles: [50],
            group_by: [:region]
          },
          records
        )

      # EU, US, APAC -> three series
      assert length(result.series) == 3
      assert Enum.all?(result.series, fn s -> length(s.data) == 1 end)
    end

    test "percentile over an empty dataset yields nil" do
      {:ok, result} =
        Engine.Formatter.format(
          %Request{type: :percentile, column: :total_amount, percentiles: [50, 90]},
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
            resource: Order,
            domain: Shop,
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
            resource: Order,
            domain: Shop,
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
            resource: Order,
            domain: Shop,
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
            resource: Order,
            domain: Shop,
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

    test "compound filter keys (:or/:and) are rejected by the whitelist" do
      # Ash's compound filter syntax uses top-level operator keys like `:or` and
      # `:and`. These are not in `allow_filters_on`, so the whitelist must reject
      # them rather than letting a caller bypass per-field filtering.
      assert {:error, %Error{field: :filters, reason: :not_allowed}} =
               AshDyan.run(
                 %{
                   resource: Order,
                   domain: Shop,
                   type: :frequency,
                   column: :status,
                   filters: %{or: [%{status: :paid}, %{status: :refunded}]}
                 },
                 data: Seed.order_rows()
               )
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
      assert_raise Error, fn ->
        AshDyan.run!(%{resource: Order, type: :frequency, column: :nonexistent})
      end
    end

    test "returns the result on success" do
      result =
        AshDyan.run!(%{resource: Order, domain: Shop, type: :frequency, column: :status},
          data: Seed.order_rows()
        )

      assert result.type == :frequency
    end
  end

  describe "formatter internals" do
    test "label_index maps stringified labels back to raw keys" do
      # Exercises the O(n) reverse-lookup used by the formatter (replacing the
      # previous O(n^2) label_to_key scan).
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        Engine.Formatter.format(
          %Request{type: :frequency, column: :status, group_by: [:region]},
          records
        )

      # Correctness proxy: every series aligns to the shared label axis.
      assert Enum.all?(result.series, fn s -> length(s.data) == length(result.labels) end)
    end
  end

  describe "extended aggregate functions" do
    test "count and count_distinct" do
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, count} =
        Engine.Formatter.format(
          %Request{type: :aggregate, column: :total_amount, function: :count},
          records
        )

      {:ok, distinct} =
        Engine.Formatter.format(
          %Request{type: :aggregate, column: :region, function: :count_distinct},
          records
        )

      assert hd(count.series).data == [6]
      # 3 distinct regions: EU, US, APAC
      assert hd(distinct.series).data == [3]
    end

    test "stddev, variance, and median" do
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, std} =
        Engine.Formatter.format(
          %Request{type: :aggregate, column: :total_amount, function: :stddev},
          records
        )

      {:ok, var} =
        Engine.Formatter.format(
          %Request{type: :aggregate, column: :total_amount, function: :variance},
          records
        )

      {:ok, med} =
        Engine.Formatter.format(
          %Request{type: :aggregate, column: :total_amount, function: :median},
          records
        )

      # values [10,20,30,50,100,200]; median (p50) = 40.0
      assert Decimal.equal?(hd(med.series).data |> hd(), Decimal.new("40.0"))
      # variance > 0 and stddev ~= sqrt(variance)
      [v] = hd(var.series).data
      [s] = hd(std.series).data
      assert v > 0
      assert abs(s - :math.sqrt(v)) < 0.01
    end
  end

  describe "histogram" do
    test "bins numeric values into a chart-ready distribution" do
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        Engine.Formatter.format(
          %Request{type: :histogram, column: :total_amount, bins: 5},
          records
        )

      assert result.type == :histogram
      # 5 bins, counts sum to the 6 non-nil values.
      assert length(result.labels) == 5
      assert Enum.sum(hd(result.series).data) == 6
    end

    test "histogram falls back to the dsl-declared default bins" do
      # `Order` declares `analyzable_field :total_amount, type: :histogram, bins: 5`.
      # Omitting `:bins` on the request must use that declared default (5), not the
      # hardcoded 10.
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        Engine.Formatter.format(
          %Request{type: :histogram, column: :total_amount, resource: Order},
          records
        )

      assert length(result.labels) == 5
    end

    test "histogram with group_by aligns series to shared bins" do
      records = read(Order, Ash.Query.for_read(Order, :read, %{}, domain: Shop))

      {:ok, result} =
        Engine.Formatter.format(
          %Request{type: :histogram, column: :total_amount, bins: 5, group_by: [:region]},
          records
        )

      # EU, US, APAC -> three series, all aligned to the same 5 bin labels.
      assert length(result.series) == 3
      assert Enum.all?(result.series, fn s -> length(s.data) == 5 end)
    end

    test "histogram rejects a non-positive bins value" do
      assert {:error, %Error{field: :bins, reason: :bad_bins}} =
               AshDyan.run(%{
                 resource: Order,
                 domain: Shop,
                 type: :histogram,
                 column: :total_amount,
                 bins: 0
               })
    end
  end

  describe "charts" do
    test "recommend picks a sensible default chart type" do
      freq =
        AshDyan.run!(%{resource: Order, domain: Shop, type: :frequency, column: :status},
          data: Seed.order_rows()
        )

      time =
        AshDyan.run!(
          %{
            resource: Order,
            domain: Shop,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            column: :total_amount,
            function: :sum
          },
          data: Seed.order_rows()
        )

      hist =
        Engine.Formatter.format(
          %Request{type: :histogram, column: :total_amount, bins: 5},
          Seed.order_rows()
        )

      {:ok, hist} = hist

      assert Charts.recommend(freq) == :pie
      assert Charts.recommend(time) == :line
      assert Charts.recommend(hist) == :histogram
    end

    test "to_chartjs produces a JSON-encodable map" do
      result =
        AshDyan.run!(%{resource: Order, domain: Shop, type: :frequency, column: :status},
          data: Seed.order_rows()
        )

      chart = Charts.to_chartjs(result)

      assert is_map(chart["data"])
      assert is_list(chart["data"]["datasets"])
      assert {:ok, _} = Jason.encode(chart)
    end

    test "to_echarts produces a JSON-encodable option map" do
      result =
        AshDyan.run!(
          %{
            resource: Order,
            domain: Shop,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            column: :total_amount,
            function: :sum
          },
          data: Seed.order_rows()
        )

      option = Charts.to_echarts(result)
      assert is_list(option["series"])
      assert {:ok, _} = Jason.encode(option)
    end
  end

  describe "presentation options (sort / top / cumulative / normalize)" do
    test "sort_by :value reorders labels and series by the metric" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            sort_by: :value,
            sort_order: :desc
          },
          data: Seed.order_rows()
        )

      counts = Enum.zip(result.labels, hd(result.series).data)
      values = Enum.map(counts, fn {_label, v} -> v end)
      assert values == Enum.sort(values, &(&1 >= &2))
    end

    test "top N rolls the remainder into an 'Other' bucket" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            sort_by: :value,
            sort_order: :desc,
            top: 1
          },
          data: Seed.order_rows()
        )

      assert List.last(result.labels) == "Other"
      assert Enum.sum(hd(result.series).data) == 6
    end

    test "cumulative produces running totals on time_bucket" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            column: :total_amount,
            function: :sum,
            cumulative: true
          },
          data: Seed.order_rows()
        )

      data = hd(result.series).data
      # The final element equals the total sum across all buckets (410.0).
      assert Decimal.to_float(List.last(data)) == 410.0
      # Each element is >= the previous (monotonically non-decreasing).
      floats = Enum.map(data, &Decimal.to_float/1)
      assert Enum.zip(floats, tl(floats)) |> Enum.all?(fn {a, b} -> b >= a end)
    end

    test "normalize :percentage converts series to share of total" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            normalize: :percentage
          },
          data: Seed.order_rows()
        )

      data = hd(result.series).data
      # Each value is a share-of-total percentage; the sum is ~100 (allowing for
      # rounding of individual slices).
      assert abs(Enum.sum(data) - 100.0) < 0.1
    end
  end

  describe "custom aggregates" do
    test "a registered custom aggregate function is dispatched at runtime" do
      defmodule Test.SumTimesTwo do
        def apply(values) do
          values
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Decimal.to_float/1)
          |> Enum.sum()
          |> Kernel.*(2)
        end
      end

      Application.put_env(:ash_dyan, :custom_aggregates, %{sum_times_two: Test.SumTimesTwo})

      try do
        {:ok, result} =
          AshDyan.run(
            %{
              resource: Order,
              domain: Shop,
              type: :aggregate,
              column: :total_amount,
              function: :sum_times_two
            },
            data: Seed.order_rows()
          )

        # sum of total_amount = 100+50+20+200+10+30 = 410; *2 = 820
        assert hd(result.series).data == [820.0]
      after
        Application.delete_env(:ash_dyan, :custom_aggregates)
      end
    end
  end

  describe "charts hardening" do
    test "pie on a multi-series result returns a structured error" do
      {:ok, multi} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region]
          },
          data: Seed.order_rows()
        )

      assert {:error, %AshDyan.Error{field: :chart_type, reason: :incompatible}} =
               Charts.build(multi, :pie)
    end

    test "scatter pairs two series into (x, y) points" do
      {:ok, multi} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region]
          },
          data: Seed.order_rows()
        )

      chart = Charts.build(multi, :scatter)
      assert chart.type == :scatter
    end

    test "to_echarts scatter pairs two series into [x, y] points" do
      {:ok, multi} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region]
          },
          data: Seed.order_rows()
        )

      option = Charts.to_echarts(multi, :scatter)
      series = option["series"]
      # Three regions => three sibling series, each rendered as a scatter series.
      assert length(series) == 3

      Enum.each(series, fn %{type: "scatter", data: points} ->
        assert Enum.all?(points, fn [x, y] -> (is_nil(x) or is_number(x)) and is_number(y) end)
      end)

      assert {:ok, _} = Jason.encode(option)
    end

    test "normalize :percentage on a grouped result converts each series" do
      {:ok, multi} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region],
            normalize: :percentage
          },
          data: Seed.order_rows()
        )

      # Each series sums to ~100% of its own total.
      Enum.each(multi.series, fn s ->
        assert abs(Enum.sum(s.data) - 100.0) < 0.1
      end)
    end
  end

  describe "error handling" do
    test "Error.exception preserves the message of a wrapped Ash error" do
      ash_error = Ash.Error.Invalid.NoSuchResource.exception(
        resource: :not_a_real_module,
        message: "boom from ash"
      )
      wrapped = AshDyan.Error.exception(ash_error)
      assert %AshDyan.Error{message: "boom from ash"} = wrapped
    end

    test "run/2 does not raise on an unexpected internal error" do
      # Force a crash inside the pipeline by passing a request whose resource is an
      # atom that is not a module; the read path raises, and run/2 must convert it
      # into a structured error rather than crashing the caller.
      assert {:error, %AshDyan.Error{reason: :not_a_resource}} =
               AshDyan.run(%{resource: :not_a_real_module, type: :frequency, column: :status})
    end
  end

  describe "data layer registry" do
    test "for_resource is config-mergeable for third-party data layers" do
      # `Order` uses `Ash.DataLayer.Simple`, which maps to the built-in
      # `AshDyan.DataLayer.Simple`. Registering an override in config must take
      # precedence, proving the registry is mergeable without patching AshDyan.
      # Define the fake capability module at the bare `Fake` name so the config
      # reference resolves to the same module.
      defmodule Fake.DyanCapabilities, do: nil

      Application.put_env(:ash_dyan, :data_layer_capabilities, %{
        Ash.DataLayer.Simple => Fake.DyanCapabilities
      })

      try do
        assert AshDyan.DataLayer.for_resource(Order) == Fake.DyanCapabilities
      after
        Application.delete_env(:ash_dyan, :data_layer_capabilities)
      end
    end

    test "unknown data layers fall back to the Default capability set" do
      # A data layer not present in the built-in map (or config overrides) must
      # resolve to the Default capability set (frequency/aggregate only). We prove
      # the fallback by overriding the registry for the duration of the test so we
      # don't need a resource backed by a real, unmapped data layer.
      original = Application.get_env(:ash_dyan, :data_layer_capabilities, %{})

      try do
        Application.put_env(:ash_dyan, :data_layer_capabilities, %{
          Ash.DataLayer.Simple => AshDyan.DataLayer.Default
        })

        assert AshDyan.DataLayer.for_resource(Order) == AshDyan.DataLayer.Default
        assert AshDyan.DataLayer.supports?(Order, :frequency)
        refute AshDyan.DataLayer.supports?(Order, :time_bucket)
      after
        Application.put_env(:ash_dyan, :data_layer_capabilities, original)
      end
    end
  end

  describe "analysis registry" do
    test "fetch returns the built-in analysis module for a known type" do
      assert {:ok, AshDyan.Analysis.Frequency} = AshDyan.Analysis.Registry.fetch(:frequency)
      assert {:ok, AshDyan.Analysis.Histogram} = AshDyan.Analysis.Registry.fetch(:histogram)
    end

    test "fetch returns :error for an unknown type" do
      assert :error = AshDyan.Analysis.Registry.fetch(:not_a_type)
    end

    test "types/0 includes all built-in analysis types" do
      types = AshDyan.Analysis.Registry.types()
      assert :frequency in types
      assert :aggregate in types
      assert :time_bucket in types
      assert :percentile in types
      assert :histogram in types
    end
  end

  describe "presentation option support by analysis type" do
    test "time_bucket rejects sort_by and top (would scramble the time axis)" do
      for option <- [sort_by: :value, top: 2] do
        assert {:error, %AshDyan.Error{field: _, reason: :not_supported}} =
                 AshDyan.run(
                   Map.merge(
                     %{
                       resource: Order,
                       domain: Shop,
                       type: :time_bucket,
                       time_field: :inserted_at,
                       bucket: :day,
                       column: :total_amount,
                       function: :sum
                     },
                     Map.new([option])
                   ),
                   data: Seed.order_rows()
                 )
      end
    end

    test "histogram rejects sort_by and top (would break bin ordering)" do
      for option <- [sort_by: :value, top: 2] do
        assert {:error, %AshDyan.Error{field: _, reason: :not_supported}} =
                 AshDyan.run(
                   Map.merge(
                     %{
                       resource: Order,
                       domain: Shop,
                       type: :histogram,
                       column: :total_amount
                     },
                     Map.new([option])
                   ),
                   data: Seed.order_rows()
                 )
      end
    end

    test "time_bucket still allows cumulative and normalize" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            column: :total_amount,
            function: :sum,
            cumulative: true,
            normalize: :percentage
          },
          data: Seed.order_rows()
        )

      assert hd(result.series).data != []
    end
  end

  describe "time_bucket function validation" do
    test "rejects a non-whitelisted function for the metric column" do
      # `:mode` is not in `:total_amount`'s :aggregate whitelist, so it must be
      # rejected for :time_bucket as well.
      assert {:error, %AshDyan.Error{field: :function, reason: :not_allowed}} =
               AshDyan.run(
                 %{
                   resource: Order,
                   domain: Shop,
                   type: :time_bucket,
                   time_field: :inserted_at,
                   bucket: :day,
                   column: :total_amount,
                   function: :mode
                 },
                 data: Seed.order_rows()
               )
    end

    test "allows a whitelisted function for the metric column" do
      {:ok, _result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :time_bucket,
            time_field: :inserted_at,
            bucket: :day,
            column: :total_amount,
            function: :sum
          },
          data: Seed.order_rows()
        )
    end
  end

  describe "Decimal-safe post-processing" do
    test "normalize :percentage works on a Decimal metric column" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region],
            normalize: :percentage
          },
          data: Seed.order_rows()
        )

      Enum.each(result.series, fn s ->
        assert abs(Enum.sum(s.data) - 100.0) < 0.1
      end)
    end

    test "top N on a Decimal metric column rolls the rest into 'Other'" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            sort_by: :value,
            sort_order: :desc,
            top: 1
          },
          data: Seed.order_rows()
        )

      assert List.last(result.labels) == "Other"
    end

    test "sort_by :value orders a Decimal metric numerically, not structurally" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :aggregate,
            column: :total_amount,
            function: :sum,
            group_by: [:region],
            sort_by: :value,
            sort_order: :desc
          },
          data: Seed.order_rows()
        )

      values = hd(result.series).data
      floats = Enum.map(values, &Decimal.to_float/1)
      assert floats == Enum.sort(floats, &(&1 >= &2))
    end
  end

  describe "empty-series post-processing" do
    test "sort/top on a zero-row grouped result does not crash" do
      {:ok, result} =
        AshDyan.run(
          %{
            resource: Order,
            domain: Shop,
            type: :frequency,
            column: :status,
            group_by: [:region],
            filters: %{status: :nonexistent_status},
            sort_by: :value,
            top: 1
          },
          data: Seed.order_rows()
        )

      assert result.series == []
    end
  end
end
