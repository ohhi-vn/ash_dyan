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

  alias AshDyan.Engine.TimeBucket
  alias AshDyan.{Request, Result}

  @doc """
  Format raw records into an `AshDyan.Result`.
  """
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

  def frequency(%{column: column, group_by: []}, records) do
    counts = Enum.frequencies_by(records, fn row -> to_label(Map.get(row, column)) end)
    labels = Map.keys(counts) |> Enum.sort()
    data = Enum.map(labels, fn label -> Map.get(counts, label, 0) end)

    %Result{
      type: :frequency,
      labels: labels,
      series: [%{name: to_string(column), data: data}]
    }
  end

  def frequency(%{column: column, group_by: group_by}, records) do
    pivot(records, column, group_by, fn rows -> length(rows) end, :frequency)
  end

  # --- aggregate ---

  def aggregate(%{column: column, function: function, group_by: []}, records) do
    values = Enum.map(records, fn row -> Map.get(row, column) end)
    value = apply_agg(function, values)

    %Result{
      type: :aggregate,
      labels: [to_string(column)],
      series: [%{name: to_string(function), data: [value]}]
    }
  end

  def aggregate(%{column: column, function: function, group_by: group_by}, records) do
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

  def time_bucket(
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
        Map.put(row, :__dyan_bucket__, TimeBucket.label(ts, bucket))
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
        :time_bucket
      )
    end
  end

  # --- percentile ---

  def percentile(%{column: column, percentiles: percentiles, group_by: []}, records) do
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

  def percentile(%{column: column, percentiles: percentiles, group_by: group_by}, records) do
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
      |> Enum.sort_by(& &1.name)

    %Result{
      type: :percentile,
      labels: Enum.map(percentiles, fn p -> "#{p}th" end),
      series: series
    }
  end

  # --- shared post-processing (sort / top-N / cumulative / normalize) ---

  # Applies the cross-cutting presentation options declared on the request:
  # `:sort_by`/`:sort_order` reorder the labels+series; `:top` keeps the N
  # largest slices and rolls the remainder into an "Other" bucket; `:cumulative`
  # computes running totals per series; `:normalize` converts each series to a
  # share-of-total percentage.
  def post_process(request, %Result{} = result) do
    result
    |> sort_result(request)
    |> top_result(request)
    |> cumulative_result(request)
    |> normalize_result(request)
  end

  defp sort_result(%Result{series: []} = result, _request), do: result

  defp sort_result(%Result{} = result, %{sort_by: nil}), do: result

  defp sort_result(%Result{labels: labels, series: series} = result, %{
         sort_by: sort_by,
         sort_order: sort_order
       }) do
    # Sort by the first series' values when sorting by :value (a single-series
    # view); for :label we sort the labels alphabetically. The sorter is
    # Decimal-aware: Elixir's `:asc`/`:desc` compare structs structurally, which
    # is wrong for `Decimal` values.
    key_fn = fn {label, i} ->
      case sort_by do
        :label -> label
        :value -> Enum.at(series, 0).data |> Enum.at(i, 0)
      end
    end

    sorter =
      case sort_order do
        :asc -> fn a, b -> compare_values(a, b) == :lt end
        :desc -> fn a, b -> compare_values(a, b) == :gt end
      end

    indexed = Enum.sort_by(Enum.with_index(labels), key_fn, sorter)

    ordered_labels = Enum.map(indexed, fn {label, _} -> label end)
    ordered_data = fn data -> Enum.map(indexed, fn {_, i} -> Enum.at(data, i) end) end

    %Result{
      result
      | labels: ordered_labels,
        series: Enum.map(series, fn s -> %{s | data: ordered_data.(s.data)} end)
    }
  end

  defp top_result(%Result{series: []} = result, _request), do: result

  defp top_result(result, %{top: nil}), do: result

  defp top_result(%Result{labels: labels, series: series} = result, %{top: top} = request) do
    # Rank label indices by the first series' value (desc), keep the top `top`,
    # and roll the rest into an "Other" bucket whose value is the per-series sum
    # of the dropped slices. Ranking uses `compare_values/2` so `Decimal`
    # metrics order numerically rather than by struct shape.
    ranked =
      labels
      |> Enum.with_index()
      |> Enum.sort_by(
        fn {_, i} -> Enum.at(series, 0).data |> Enum.at(i, 0) || 0 end,
        fn a, b -> compare_values(a, b) == :gt end
      )

    {keep, drop} = Enum.split(ranked, top)

    keep_labels = Enum.map(keep, fn {label, _} -> label end)

    kept_data =
      Enum.map(series, fn s ->
        values = Enum.map(keep, fn {_, i} -> Enum.at(s.data, i) end)
        %{s | data: values}
      end)

    if drop == [] do
      %Result{result | labels: keep_labels, series: kept_data}
    else
      other_data =
        Enum.map(series, fn s ->
          sum =
            Enum.map(drop, fn {_, i} -> Enum.at(s.data, i) end)
            |> Enum.reject(&is_nil/1)
            |> sum_values()

          %{s | data: Enum.map(keep, fn {_, i} -> Enum.at(s.data, i) end) ++ [sum]}
        end)

      other_labels = keep_labels ++ ["Other"]

      # When the caller asked to sort by label, present the kept slices
      # alphabetically (pinning "Other" last) rather than in value order.
      {final_labels, final_data} =
        if request.sort_by == :label do
          reorder_by_label(other_labels, other_data)
        else
          {other_labels, other_data}
        end

      %Result{result | labels: final_labels, series: final_data}
    end
  end

  # Re-sort labels alphabetically while pinning the synthetic "Other" bucket to
  # the end, keeping each series' `data` aligned to the new label order.
  defp reorder_by_label(labels, series) do
    ordered =
      labels
      |> Enum.with_index()
      |> Enum.sort_by(fn {label, _} ->
        if label == "Other", do: {:other, label}, else: {:label, label}
      end)

    ordered_labels = Enum.map(ordered, fn {label, _} -> label end)

    reorder = fn data -> Enum.map(ordered, fn {_, i} -> Enum.at(data, i) end) end

    {ordered_labels, Enum.map(series, fn s -> %{s | data: reorder.(s.data)} end)}
  end

  defp cumulative_result(result, %{cumulative: false}), do: result

  defp cumulative_result(%Result{series: series} = result, %{cumulative: true}) do
    cumulative =
      Enum.map(series, fn s ->
        {running, _} =
          Enum.map_reduce(s.data, 0, fn v, acc ->
            new_acc = if(is_nil(v), do: acc, else: add_values(acc, v))
            {new_acc, new_acc}
          end)

        %{s | data: running}
      end)

    %Result{result | series: cumulative}
  end

  # Decimal-aware addition so cumulative totals work on decimal metrics.
  defp add_values(%Decimal{} = a, %Decimal{} = b), do: Decimal.add(a, b)
  defp add_values(%Decimal{} = a, b) when is_number(b), do: Decimal.add(a, Decimal.new(b))
  defp add_values(a, %Decimal{} = b) when is_number(a), do: Decimal.add(Decimal.new(a), b)
  defp add_values(a, b), do: a + b

  # --- Decimal-safe presentation helpers ---

  # Sum a list of values, branching on whether they are `Decimal`s. `Enum.sum/1`
  # raises `ArithmeticError` on `Decimal` structs, so we reduce with `Decimal.add`.
  defp sum_values([]), do: 0

  defp sum_values(values) do
    case Enum.find(values, &(&1 != nil)) do
      %Decimal{} ->
        values
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      _ ->
        Enum.sum(values)
    end
  end

  # Numeric comparison that works for `Decimal`, numbers, and `nil`. Elixir's
  # `:asc`/`:desc` sorter compares structs structurally, which is wrong for
  # `Decimal` (it would order by the underlying map fields, not the value).
  defp compare_values(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b)

  defp compare_values(%Decimal{} = a, b) when is_number(b),
    do: Decimal.compare(a, Decimal.from_float(b * 1.0))

  defp compare_values(a, %Decimal{} = b) when is_number(a),
    do: Decimal.compare(Decimal.from_float(a * 1.0), b)

  defp compare_values(nil, nil), do: :eq
  defp compare_values(nil, _), do: :lt
  defp compare_values(_, nil), do: :gt
  defp compare_values(a, b) when a < b, do: :lt
  defp compare_values(a, b) when a > b, do: :gt
  defp compare_values(_, _), do: :eq

  # Share-of-total percentage for a single value. `Decimal` division must go
  # through `Decimal.div/2`; the result is converted to a float for display.
  defp percentage_of(v, total) do
    ratio =
      case {v, total} do
        {%Decimal{}, %Decimal{}} -> Decimal.div(v, total)
        {%Decimal{}, t} when is_number(t) -> Decimal.div(v, Decimal.from_float(t * 1.0))
        {val, %Decimal{}} when is_number(val) -> Decimal.div(Decimal.from_float(val * 1.0), total)
        {val, t} when is_number(val) and is_number(t) -> val / t
      end

    case ratio do
      %Decimal{} -> Decimal.to_float(ratio) * 100
      n when is_number(n) -> n * 100
    end
  end

  defp zero_value?(%Decimal{} = d), do: Decimal.compare(d, Decimal.new(0)) == :eq
  defp zero_value?(n) when is_number(n), do: n == 0
  defp zero_value?(nil), do: true

  defp normalize_result(result, %{normalize: nil}), do: result

  defp normalize_result(%Result{series: series} = result, %{normalize: :percentage}) do
    normalized =
      Enum.map(series, fn s ->
        total = s.data |> Enum.reject(&is_nil/1) |> sum_values()

        data =
          Enum.map(s.data, fn v ->
            if is_nil(v) or zero_value?(total) do
              0.0
            else
              Float.round(percentage_of(v, total), 6)
            end
          end)

        %{s | data: data}
      end)

    %Result{result | series: normalized}
  end

  # --- shared helpers ---

  # Pivot: `label_field` becomes the sorted `labels` axis; each distinct
  # `group_by` combination becomes a series whose `data` is aligned to `labels`.
  defp pivot(records, label_field, group_by, aggregate_fn, type) do
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
      |> Enum.sort_by(& &1.name)

    %Result{type: type, labels: labels, series: series}
  end

  defp group_key(row, group_by) do
    Enum.map(group_by, fn g -> Map.get(row, g) end)
  end

  # --- histogram ---

  # Numeric distribution into bins. `bin_width` is auto-computed from the data
  # range when not supplied; `bins` (defaulting to the field's declared default,
  # then 10) controls the count. The result is chart-ready: `labels` are bin
  # ranges ("0.0-10.0"), `data` are counts.
  def histogram(
        %{column: column, group_by: []} = request,
        records
      ) do
    {bins, bin_width} = resolve_histogram_defaults(request)
    values = numeric_values(records, column)
    {min, bin_width, labels} = bin_spec(values, bins, bin_width)
    data = bin_counts_with(values, min, bin_width, length(labels))

    %Result{
      type: :histogram,
      labels: labels,
      series: [%{name: to_string(column), data: data}]
    }
  end

  def histogram(
        %{column: column, bins: _bins, bin_width: _bin_width, group_by: group_by} = request,
        records
      ) do
    {bins, bin_width} = resolve_histogram_defaults(request)
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
      |> Enum.sort_by(& &1.name)

    %Result{type: :histogram, labels: base_labels, series: series}
  end

  # Resolve the effective `bins`/`bin_width` for a histogram request, falling
  # back to the field's declared defaults (from the `dyan` DSL) and then to the
  # hardcoded 10-bins default.
  defp resolve_histogram_defaults(%{
         resource: resource,
         column: column,
         bins: bins,
         bin_width: bin_width
       }) do
    field =
      if resource, do: AshDyan.Info.analyzable_field(resource, column, :histogram), else: nil

    bins = bins || (field && field.bins) || 10
    bin_width = bin_width || (field && field.bin_width)
    {bins, bin_width}
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
    {bin_width, _bin_count, labels} = compute_bins(min, max, bins, bin_width)
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

  defp compute_bins(min, max, bins, nil) do
    bin_count = max(bins || 10, 1)
    span = max - min
    bin_width = if span == 0, do: 1.0, else: span / bin_count

    labels =
      Enum.map(0..(bin_count - 1), fn i ->
        lo = min + i * bin_width
        hi = lo + bin_width
        format_bin(lo, hi)
      end)

    {bin_width, bin_count, labels}
  end

  defp compute_bins(min, max, _bins, bin_width) when is_number(bin_width) do
    bin_count = max(ceil((max - min) / bin_width), 1)

    labels =
      Enum.map(0..(bin_count - 1), fn i ->
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

  defp apply_agg(function, values) do
    # Third-party aggregate functions can be registered at runtime via
    # `config :ash_dyan, :custom_aggregates, %{my_fn: MyModule}`. Built-ins are
    # handled by `apply_builtin_agg/2`.
    case Application.get_env(:ash_dyan, :custom_aggregates, %{})[function] do
      nil -> apply_builtin_agg(function, values)
      module -> module.apply(values)
    end
  end

  defp apply_builtin_agg(:count, values), do: length(values)

  defp apply_builtin_agg(:count_distinct, values),
    do: values |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

  defp apply_builtin_agg(:sum, values), do: aggregate_numbers(values, &Decimal.add/2, 0)
  defp apply_builtin_agg(:min, values), do: safe_enum(values, &Enum.min/1)
  defp apply_builtin_agg(:max, values), do: safe_enum(values, &Enum.max/1)
  defp apply_builtin_agg(:avg, values), do: average_numbers(values)
  defp apply_builtin_agg(:median, values), do: percentile_of(Enum.reject(values, &is_nil/1), 50)
  defp apply_builtin_agg(:stddev, values), do: stddev(values)
  defp apply_builtin_agg(:variance, values), do: variance(values)

  defp apply_builtin_agg(function, _values),
    do: raise(ArgumentError, "unknown aggregate function #{inspect(function)}")

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
        values
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(zero, &Kernel.+/2)
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
  defp group_name(list), do: list |> Enum.map_join("/", &to_label/1)
end
