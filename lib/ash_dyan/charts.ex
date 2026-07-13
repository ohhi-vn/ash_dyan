defmodule AshDyan.Charts do
  @moduledoc """
  Turn an `AshDyan.Result` into chart-library-ready shapes.

  `AshDyan.run/1` returns a stable `labels`/`series` structure. This module maps
  that structure onto common chart types and serializes it for popular charting
  libraries, so a client can render a chart without knowing AshDyan's internals.

  ## Chart types

  - `:bar` — categorical counts / grouped aggregates.
  - `:line` — time-bucketed series, percentiles, or any ordered axis.
  - `:area` — like `:line` but filled (good for cumulative / time series).
  - `:pie` / `:donut` — single-series frequency or aggregate breakdowns.
  - `:histogram` — binned numeric distribution (the `:histogram` result type).
  - `:scatter` — (x, y) pairs when a result has exactly two series; the two
    series are paired index-by-index into points. For a single or more-than-two
    series result, each series is rendered as its own (x=nil, y=value) scatter.

  ## Recommendation

  `recommend/1` picks a sensible default chart type from the result's `type` and
  shape, so a generic UI can render something reasonable without per-call config.

  ## Serialization

  - `to_chartjs/2` — returns a Chart.js `data`/`options` map (JSON-encodable).
  - `to_echarts/2` — returns an ECharts `option` map (JSON-encodable).
  """

  alias AshDyan.Result

  @type chart_type :: :bar | :line | :area | :pie | :donut | :histogram | :scatter

  @doc """
  Pick a default chart type for a result.

  - `:frequency` → `:bar` (or `:pie` when there is a single series).
  - `:aggregate` → `:bar` (or `:pie` for a single series).
  - `:time_bucket` → `:line`.
  - `:percentile` → `:line`.
  - `:histogram` → `:histogram`.
  """
  @spec recommend(Result.t()) :: chart_type()
  def recommend(%Result{type: type} = result) do
    case AshDyan.Analysis.Registry.fetch(type) do
      {:ok, module} -> module.recommend_chart(result)
      :error -> :bar
    end
  end

  @doc """
  Build a chart-ready map for the given chart type.

  Returns `%{type: chart_type, labels: [...], series: [...], options: %{}}`. If
  `chart_type` is omitted, `recommend/1` is used.
  """
  @spec build(Result.t(), chart_type() | nil) :: map() | {:error, AshDyan.Error.t()}
  def build(%Result{} = result, nil), do: build(result, recommend(result))

  def build(%Result{} = result, chart_type)
      when chart_type in [:bar, :line, :area, :pie, :donut, :histogram, :scatter] do
    with :ok <- assert_single_series(result, chart_type) do
      %{
        type: chart_type,
        labels: result.labels,
        series: result.series,
        options: %{title: nil}
      }
    end
  end

  @doc """
  Serialize a result to a Chart.js `data`/`options` map.

  `chart_type` is optional (defaults to `recommend/1`). The returned map is
  JSON-encodable via `Jason.encode!/1`.
  """
  @spec to_chartjs(Result.t(), chart_type() | nil) :: map() | {:error, AshDyan.Error.t()}
  def to_chartjs(%Result{} = result, chart_type \\ nil) do
    chart_type = chart_type || recommend(result)

    with :ok <- assert_single_series(result, chart_type) do
      datasets = chartjs_datasets(result, chart_type)

      %{
        "type" => chartjs_type(chart_type),
        "data" => %{"labels" => result.labels, "datasets" => datasets},
        "options" => %{
          "responsive" => true,
          "plugins" => %{"legend" => %{"display" => length(result.series) > 1}}
        }
      }
    end
  end

  @doc """
  Serialize a result to an ECharts `option` map.

  `chart_type` is optional (defaults to `recommend/1`). The returned map is
  JSON-encodable via `Jason.encode!/1`.
  """
  @spec to_echarts(Result.t(), chart_type() | nil) :: map() | {:error, AshDyan.Error.t()}
  def to_echarts(%Result{} = result, chart_type \\ nil) do
    chart_type = chart_type || recommend(result)

    with :ok <- assert_single_series(result, chart_type) do
      series =
        if chart_type == :scatter do
          echarts_scatter_series(result)
        else
          Enum.map(result.series, fn s ->
            echarts_series(chart_type, result.labels, s)
          end)
        end

      %{
        "tooltip" => %{"trigger" => echarts_tooltip_trigger(chart_type)},
        "legend" => %{"data" => Enum.map(result.series, & &1.name)},
        "xAxis" => echarts_x_axis(chart_type, result.labels),
        "yAxis" => echarts_y_axis(chart_type),
        "series" => series
      }
    end
  end

  # `:pie`/`:donut` require exactly one series; a multi-series result has no
  # single slice set to render, so reject it rather than raising a MatchError.
  defp assert_single_series(%Result{series: series}, chart_type)
       when chart_type in [:pie, :donut] and length(series) != 1 do
    {:error,
     AshDyan.Error.exception(
       field: :chart_type,
       reason: :incompatible,
       message: "#{chart_type} requires exactly one series, got #{length(series)}"
     )}
  end

  defp assert_single_series(_result, _chart_type), do: :ok

  defp chartjs_type(:area), do: "line"
  defp chartjs_type(:donut), do: "doughnut"
  defp chartjs_type(:histogram), do: "bar"
  defp chartjs_type(other), do: to_string(other)

  defp chartjs_datasets(%Result{series: series}, :pie) do
    [single] = series
    [%{label: single.name, data: single.data, backgroundColor: palette(length(single.data))}]
  end

  defp chartjs_datasets(%Result{series: series}, :donut) do
    [single] = series
    [%{label: single.name, data: single.data, backgroundColor: palette(length(single.data))}]
  end

  defp chartjs_datasets(%Result{series: series}, :area) do
    Enum.with_index(series)
    |> Enum.map(fn {s, i} ->
      %{
        label: s.name,
        data: s.data,
        fill: true,
        borderColor: color(i),
        backgroundColor: color(i, 0.2)
      }
    end)
  end

  defp chartjs_datasets(%Result{series: [x, y]}, :scatter) do
    pairs =
      Enum.zip(x.data, y.data)
      |> Enum.map(fn {a, b} -> %{x: a, y: b} end)

    [%{label: "#{x.name} vs #{y.name}", data: pairs, backgroundColor: color(0)}]
  end

  defp chartjs_datasets(%Result{series: series}, :scatter) do
    Enum.with_index(series)
    |> Enum.map(fn {s, i} ->
      %{
        label: s.name,
        data: Enum.map(s.data, fn v -> %{x: nil, y: v} end),
        backgroundColor: color(i)
      }
    end)
  end

  defp chartjs_datasets(%Result{series: series}, _chart_type) do
    Enum.with_index(series)
    |> Enum.map(fn {s, i} ->
      %{label: s.name, data: s.data, borderColor: color(i), backgroundColor: color(i)}
    end)
  end

  defp echarts_series(:pie, labels, s) do
    names =
      if labels == [] do
        Enum.map(0..(length(s.data) - 1), &to_string/1)
      else
        labels
      end

    %{
      name: s.name,
      type: "pie",
      data:
        Enum.map(Enum.with_index(s.data), fn {v, i} ->
          %{name: Enum.at(names, i), value: v}
        end)
    }
  end

  defp echarts_series(:donut, labels, s) do
    Map.put(echarts_series(:pie, labels, s), :radius, ["40%", "70%"])
  end

  defp echarts_series(:area, labels, s) do
    %{
      name: s.name,
      type: "line",
      areaStyle: %{},
      data: Enum.zip_with(labels, s.data, fn l, v -> [l, v] end)
    }
  end

  defp echarts_series(:histogram, _labels, s) do
    %{name: s.name, type: "bar", data: s.data, barCategoryGap: "10%"}
  end

  defp echarts_series(:scatter, _labels, s) do
    %{name: s.name, type: "scatter", data: Enum.map(s.data, fn v -> [nil, v] end)}
  end

  defp echarts_series(_chart_type, _labels, s) do
    %{name: s.name, type: "bar", data: s.data}
  end

  # Pair two sibling series into (x, y) points. Falls back to per-series scatter
  # when the result does not have exactly two series.
  defp echarts_scatter_series(%Result{series: [x, y]}) do
    data = Enum.zip_with(x.data, y.data, fn a, b -> [a, b] end)
    [%{name: "#{x.name} vs #{y.name}", type: "scatter", data: data}]
  end

  defp echarts_scatter_series(%Result{series: series}) do
    Enum.map(series, fn s ->
      %{name: s.name, type: "scatter", data: Enum.map(s.data, fn v -> [nil, v] end)}
    end)
  end

  defp echarts_tooltip_trigger(:pie), do: "item"
  defp echarts_tooltip_trigger(:donut), do: "item"
  defp echarts_tooltip_trigger(:scatter), do: "item"
  defp echarts_tooltip_trigger(_), do: "axis"

  defp echarts_x_axis(:pie, _labels), do: nil
  defp echarts_x_axis(:donut, _labels), do: nil
  defp echarts_x_axis(_chart_type, labels), do: %{type: "category", data: labels}

  defp echarts_y_axis(:pie), do: nil
  defp echarts_y_axis(:donut), do: nil
  defp echarts_y_axis(_chart_type), do: %{type: "value"}

  # --- palette helpers ---

  defp palette(n) do
    Enum.map(0..(max(n, 1) - 1), fn i -> color(i) end)
  end

  @base_colors [
    "#4e79a7",
    "#f28e2b",
    "#e15759",
    "#76b7b2",
    "#59a14f",
    "#edc948",
    "#b07aa1",
    "#ff9da7",
    "#9c755f",
    "#bab0ac"
  ]

  defp color(i, alpha \\ 1.0) do
    hex = Enum.at(@base_colors, rem(i, length(@base_colors)))
    apply_alpha(hex, alpha)
  end

  defp apply_alpha(hex, 1.0), do: hex

  defp apply_alpha(hex, alpha) do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = String.trim_leading(hex, "#")

    "rgba(#{String.to_integer(r, 16)},#{String.to_integer(g, 16)},#{String.to_integer(b, 16)},#{alpha})"
  end
end
