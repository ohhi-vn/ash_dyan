defmodule AshDyan.Engine.Formatter do
  @moduledoc """
  Aggregates raw Ash records (returned by the read action) in memory into the
  stable `labels`/`series` output shape.

  Output conventions (so a client-side chart adapter needs no per-type branching):

  - `:frequency` (no group_by): `labels` = distinct column values; one series
    named after the column with the counts.
  - `:frequency` (group_by): `labels` = distinct column values; one series per
    group_by combination, each series's `data` aligned to `labels`.
  - `:aggregate` (no group_by): `labels` = `[column]`; one series named after the
    function.
  - `:aggregate` (group_by): `labels` = distinct group_by combinations; one
    series named after the function.
  - `:time_bucket`: `labels` = bucket labels; series per group_by combination
    (or a single series named after the function when there is no group_by).
  - `:percentile`: `labels` = percentile labels; series per group_by combination
    (or a single series named after the column when there is no group_by).
  """

  alias AshDyan.{Request, Result}

  @doc "Format raw records into an `AshDyan.Result`."
  @spec format(Request.t(), [Ash.Resource.Record.t()]) :: {:ok, Result.t()} | {:error, term()}
  def format(%Request{type: :frequency} = request, records) do
    {:ok, frequency(request, records)}
  end

  def format(%Request{type: :aggregate} = request, records) do
    {:ok, aggregate(request, records)}
  end

  def format(%Request{type: :time_bucket} = request, records) do
    {:ok, time_bucket(request, records)}
  end

  def format(%Request{type: :percentile} = request, records) do
    {:ok, percentile(request, records)}
  end

  def format(%Request{type: :histogram} = request, records) do
    {:ok, histogram(request, records)}
  end

  # --- frequency ---

  defp frequency(%{column: column, group_by: []}, records) do
    counts = Enum.frequencies_by(records, fn row -> to_label(Map.get(row, column)) end)
    labels = Map.keys(counts) |> Enum.sort()
    data = Enum.map(labels, fn label -> Map.get(counts, label, 0) end)

    %Result{
      type: :frequency,
      labels: labels,
      series: [%{name: to_string(column), data: data}]
    }
  end

  defp frequency(%{column: column, group_by: group_by}, records) do
    pivot(records, column, group_by, fn rows -> length(rows) end, to_string(column), :frequency)
  end

  # --- aggregate ---

  defp aggregate(%{column: column, function: function, group_by: []}, records) do
    values = Enum.map(records, fn row -> Map.get(row, column) end)
    value = apply_agg(function, values)

    %Result{
      type: :aggregate,
      labels: [to_string(column)],
      series: [%{name: to_string(function), data: [value]}]
    }
  end

  defp aggregate(%{column: column, function: function, group_by: group_by}, records) do
    grouped = Enum.group_by(records, fn row -> group_name(group_key(row, group_by)) end)

    labels = Map.keys(grouped) |> Enum.sort()

    data =
      Enum.map(labels, fn label ->
        rows = Map.get(grouped, label, [])
        apply_agg(function, Enum.map(rows, fn row -> Map.get(row, column) end))
      end)

    %Result{
      type: :aggregate,
      labels: labels,
      series: [%{name: to_string(function), data: data}]
    }
  end

  # --- time_bucket ---

  defp time_bucket(
         %{
           bucket: bucket,
           time_field: time_field,
           column: column,
           function: function,
           group_by: group_by
         },
         records
       ) do
    time_field = time_field || column

    enriched =
      Enum.map(records, fn row ->
        ts = Map.get(row, time_field)
        Map.put(row, :__dyan_bucket__, AshDyan.Engine.TimeBucket.label(ts, bucket))
      end)

    if group_by == [] do
      grouped = Enum.group_by(enriched, fn row -> row.__dyan_bucket__ end)

      labels = Map.keys(grouped) |> Enum.sort()

      data =
        Enum.map(labels, fn label ->
          rows = Map.get(grouped, label, [])
          apply_agg(function || :count, Enum.map(rows, fn row -> Map.get(row, column) end))
        end)

      %Result{
        type: :time_bucket,
        labels: labels,
        series: [%{name: to_string(function || :count), data: data}]
      }
    else
      pivot(
        enriched,
        :__dyan_bucket__,
        group_by,
        fn rows ->
          apply_agg(function || :count, Enum.map(rows, fn row -> Map.get(row, column) end))
        end,
        to_string(function || :count),
        :time_bucket
      )
    end
  end

  # --- percentile ---

  defp percentile(%{column: column, percentiles: percentiles, group_by: []}, records) do
    values =
      records
      |> Enum.map(fn row -> Map.get(row, column) end)
      |> Enum.reject(&is_nil/1)

    data = Enum.map(percentiles, fn p -> percentile_of(values, p) end)

    %Result{
      type: :percentile,
      labels: Enum.map(percentiles, fn p -> "#{p}th" end),
      series: [%{name: to_string(column), data: data}]
    }
  end

  defp percentile(%{column: column, percentiles: percentiles, group_by: group_by}, records) do
    grouped = Enum.group_by(records, fn row -> group_name(group_key(row, group_by)) end)

    series =
      Enum.map(grouped, fn {name, rows} ->
        values =
          rows
          |> Enum.map(fn row -> Map.get(row, column) end)
          |> Enum.reject(&is_nil/1)

        data = Enum.map(percentiles, fn p -> percentile_of(values, p) end)
        %{name: name, data: data}
      end)

    %Result{
      type: :percentile,
      labels: Enum.map(percentiles, fn p -> "#{p}th" end),
      series: series
    }
  end

  # --- shared helpers ---

  # Pivot: `label_field` becomes the sorted `labels` axis; each distinct
  # `group_by` combination becomes a series whose `data` is aligned to `labels`.
  defp pivot(records, label_field, group_by, aggregate_fn, _series_base_name, type) do
    grouped = Enum.group_by(records, fn row -> group_name(group_key(row, group_by)) end)

    # labels across all groups
    labels =
      records
      |> Enum.map(fn row -> to_label(Map.get(row, label_field)) end)
      |> Enum.uniq()
      |> Enum.sort()

    series =
      Enum.map(grouped, fn {name, rows} ->
        by_label = Enum.group_by(rows, fn row -> to_label(Map.get(row, label_field)) end)

        data =
          Enum.map(labels, fn label ->
            aggregate_fn.(Map.get(by_label, label, []))
          end)

        %{name: name, data: data}
      end)

    %Result{type: type, labels: labels, series: series}
  end

  defp group_key(row, group_by) do
    Enum.map(group_by, fn g -> Map.get(row, g) end)
  end

  # --- histogram ---

  # Numeric distribution into bins. `bin_width` is auto-computed from the data
  # range when not supplied; `bins` (default 10) controls the count. The result
  # is chart-ready: `labels` are bin ranges ("0.0-10.0"), `data` are counts.
  defp histogram(%{column: column, bins: bins, bin_width: bin_width, group_by: []}, records) do
    values = numeric_values(records, column)
    {labels, data} = bin_counts(values, bins, bin_width)

    %Result{
      type: :histogram,
      labels: labels,
      series: [%{name: to_string(column), data: data}]
    }
  end

  defp histogram(%{column: column, bins: bins, bin_width: bin_width, group_by: group_by}, records) do
    grouped = Enum.group_by(records, fn row -> group_name(group_key(row, group_by)) end)

    # Compute bins once from the full dataset so every group's series aligns to
    # the same bin axis.
    {base_min, base_bin_width, base_labels} =
      records
      |> numeric_values(column)
      |> bin_spec(bins, bin_width)

    series =
      Enum.map(grouped, fn {name, rows} ->
        values = numeric_values(rows, column)
        data = bin_counts_with(values, base_min, base_bin_width, length(base_labels))
        %{name: name, data: data}
      end)

    %Result{type: :histogram, labels: base_labels, series: series}
  end

  defp numeric_values(records, column) do
    records
    |> Enum.map(fn row -> Map.get(row, column) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      %Decimal{} = d -> Decimal.to_float(d)
      v -> v
    end)
    |> Enum.filter(&is_number/1)
  end

  # Returns {min, bin_width, labels} for the given values.
  defp bin_spec([], _bins, _bin_width) do
    {0.0, 1.0, [format_bin(0.0, 1.0)]}
  end

  defp bin_spec(values, bins, bin_width) do
    min = Enum.min(values)
    max = Enum.max(values)
    {bin_width, _bin_count, labels} = compute_bins(min, max, bins, bin_width, nil)
    {min, bin_width, labels}
  end

  # Counts values into `bin_count` bins starting at `min` with `bin_width`.
  defp bin_counts_with(values, min, bin_width, bin_count) do
    counts = List.duplicate(0, bin_count)

    Enum.reduce(values, counts, fn v, acc ->
      idx = min(trunc((v - min) / bin_width), bin_count - 1)
      List.update_at(acc, idx, &(&1 + 1))
    end)
  end

    defp bin_counts(value, bins, bin_width, base \\ nil)
  defp bin_counts([], _bins, _bin_width, _base ) do
    {[format_bin(0.0, 1.0)], [0]}
  end

  defp bin_counts(values, bins, bin_width, _base ) do
    min = Enum.min(values)
    {_, bin_width, labels} = compute_bins(min, Enum.max(values), bins, bin_width, nil)
    {labels, bin_counts_with(values, min, bin_width, length(labels))}
  end

  defp compute_bins(min, max, bins, nil, nil) do
    bin_count = max(bins || 10, 1)
    span = max - min
    bin_width = if span == 0, do: 1.0, else: span / bin_count
    labels = Enum.map(0..(bin_count - 1), fn i ->
      lo = min + i * bin_width
      hi = lo + bin_width
      format_bin(lo, hi)
    end)
    {bin_width, bin_count, labels}
  end

  defp compute_bins(min, max, _bins, bin_width, nil) when is_number(bin_width) do
    bin_count = max(ceil((max - min) / bin_width), 1)
    labels = Enum.map(0..(bin_count - 1), fn i ->
      lo = min + i * bin_width
      hi = lo + bin_width
      format_bin(lo, hi)
    end)
    {bin_width, bin_count, labels}
  end

  defp format_bin(lo, hi) do
    "#{format_num(lo)}-#{format_num(hi)}"
  end

  defp format_num(n) when is_float(n) do
    # Trim trailing zeros for readability.
    s = :io_lib.format("~.4f", [n]) |> to_string()
    Regex.replace(~r/\.?0+$/, s, "")
  end

  defp format_num(n), do: to_string(n)

  defp safe_enum([], _fun), do: nil
  defp safe_enum(values, fun) do
    nums = Enum.reject(values, &is_nil/1)
    if nums == [], do: nil, else: fun.(nums)
  end

  defp apply_agg(:count, values), do: length(values)
  defp apply_agg(:count_distinct, values), do: values |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
  defp apply_agg(:sum, values), do: aggregate_numbers(values, &Decimal.add/2, 0)
  defp apply_agg(:min, values), do: safe_enum(values, &Enum.min/1)
  defp apply_agg(:max, values), do: safe_enum(values, &Enum.max/1)
  defp apply_agg(:avg, values), do: average_numbers(values)
  defp apply_agg(:median, values), do: percentile_of(Enum.reject(values, &is_nil/1), 50)
  defp apply_agg(:stddev, values), do: stddev(values)
  defp apply_agg(:variance, values), do: variance(values)

  defp stddev(values) do
    case variance(values) do
      nil -> nil
      v -> :math.sqrt(v)
    end
  end

  defp variance(values) do
    nums = Enum.reject(values, &is_nil/1)
    if nums == [], do: nil, else: variance_of(nums)
  end

  defp variance_of(nums) do
    case Enum.find(nums, &(&1 != nil)) do
      %Decimal{} ->
        floats = Enum.map(nums, &Decimal.to_float/1)
        variance_of_numbers(floats)

      _ ->
        variance_of_numbers(nums)
    end
  end

  defp variance_of_numbers(nums) do
    n = length(nums)
    mean = Enum.sum(nums) / n
    sum_sq = Enum.reduce(nums, 0, fn x, acc -> acc + :math.pow(x - mean, 2) end)
    sum_sq / n
  end

  # `Decimal` does not implement Elixir's `Kernel.+/2`, so sum via `Decimal.add`.
  # Numeric values use plain arithmetic. We detect the representation from the
  # first non-nil value.
  defp aggregate_numbers([], _fun, _zero), do: nil

  defp aggregate_numbers(values, fun, zero) do
    case Enum.find(values, &(&1 != nil)) do
      %Decimal{} ->
        values
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(Decimal.new(0), fun)

      _ ->
        Enum.reduce(values, zero, &Kernel.+/2)
    end
  end

  defp average_numbers([]), do: nil

  defp average_numbers(values) do
    nums = Enum.reject(values, &is_nil/1)

    case Enum.find(nums, &(&1 != nil)) do
      %Decimal{} ->
        sum = Enum.reduce(nums, Decimal.new(0), &Decimal.add/2)
        Decimal.div(sum, Decimal.new(length(nums)))

      _ ->
        Enum.sum(nums) / length(nums)
    end
  end

  defp percentile_of([], _p), do: nil

  defp percentile_of(values, p) when is_list(values) do
    case Enum.find(values, &(&1 != nil)) do
      %Decimal{} -> percentile_of_decimal(values, p)
      _ -> percentile_of_number(values, p)
    end
  end

  defp percentile_of_number(values, p) do
    sorted = Enum.sort(values)
    n = length(sorted)
    rank = p / 100 * (n - 1)
    lower = floor(rank)
    upper = ceil(rank)

    lower_val = Enum.at(sorted, lower)
    upper_val = Enum.at(sorted, upper)

    if lower == upper do
      lower_val
    else
      frac = rank - lower
      lower_val + frac * (upper_val - lower_val)
    end
  end

  defp percentile_of_decimal(values, p) do
    sorted = Enum.sort(values, &(Decimal.compare(&1, &2) != :gt))
    n = length(sorted)
    rank = Decimal.div(Decimal.new(p), Decimal.new(100))
    rank = Decimal.mult(rank, Decimal.new(n - 1))
    lower = rank |> Decimal.round(0, :floor) |> Decimal.to_integer()
    upper = rank |> Decimal.round(0, :ceiling) |> Decimal.to_integer()

    lower_val = Enum.at(sorted, lower)
    upper_val = Enum.at(sorted, upper)

    if lower == upper do
      lower_val
    else
      frac = Decimal.sub(rank, Decimal.new(lower))
      diff = Decimal.sub(upper_val, lower_val)
      Decimal.add(lower_val, Decimal.mult(frac, diff))
    end
  end

  defp to_label(nil), do: "nil"
  defp to_label(value) when is_atom(value), do: to_string(value)
  defp to_label(%Date{} = d), do: Date.to_iso8601(d)
  defp to_label(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_label(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp to_label(value), do: to_string(value)

  defp group_name([]), do: "all"
  defp group_name([single]), do: to_label(single)
  defp group_name(list), do: list |> Enum.map(&to_label/1) |> Enum.join("/")
end
