defmodule AshDyan.Engine.TimeBucket do
  @moduledoc """
  Helpers for time-bucket analysis.

  - `label/2` computes the bucket label for the in-memory aggregation path used
    by the engine (works on any data layer, including ETS/Simple).
  - `expr/2` is a reference helper that builds a Postgres `date_trunc`-style
    fragment. It is provided for a future SQL pushdown optimization; the engine
    currently aggregates time buckets in memory so the behaviour is identical
    across data layers.
  """

  @doc """
  Build a date_trunc-style expression for the given time field and bucket.

  Reference helper for a future SQL pushdown optimization.
  """
  @spec expr(atom(), AshDyan.time_bucket()) :: Macro.t()
  def expr(time_field, bucket) do
    trunc_unit = postgres_unit(bucket)

    quote do
      fragment("date_trunc(?, ?)", unquote(trunc_unit), field(unquote(time_field), :utc_datetime))
    end
  end

  @doc """
  Compute a human-readable bucket label for an in-memory fallback (ETS/Simple).

  For `:week` we use the Monday of the ISO week. For `:quarter` we use the
  quarter start month.
  """
  @spec label(DateTime.t() | NaiveDateTime.t() | Date.t() | nil, AshDyan.time_bucket()) ::
          String.t() | nil
  def label(nil, _bucket), do: "nil"

  # Hour/minute buckets need time-of-day, so route DateTime through
  # NaiveDateTime rather than collapsing straight to Date.
  def label(%DateTime{} = dt, bucket) when bucket in [:hour, :minute] do
    dt |> DateTime.to_naive() |> label(bucket)
  end

  def label(%NaiveDateTime{} = dt, :hour) do
    "#{Date.to_iso8601(NaiveDateTime.to_date(dt))} #{pad2(dt.hour)}:00"
  end

  def label(%NaiveDateTime{} = dt, :minute) do
    "#{Date.to_iso8601(NaiveDateTime.to_date(dt))} #{pad2(dt.hour)}:#{pad2(dt.minute)}"
  end

  def label(%DateTime{} = dt, bucket), do: label(NaiveDateTime.to_date(dt), bucket)
  def label(%NaiveDateTime{} = dt, bucket), do: label(NaiveDateTime.to_date(dt), bucket)

  def label(%Date{} = date, :day), do: Date.to_iso8601(date)

  def label(%Date{} = date, :week) do
    # Monday of the same week (ISO week, weeks start on Monday).
    dow = Date.day_of_week(date, :monday)
    monday = Date.add(date, 1 - dow)
    Date.to_iso8601(monday)
  end

  def label(%Date{} = date, :month), do: "#{date.year}-#{pad2(date.month)}"
  def label(%Date{} = date, :quarter), do: "#{date.year}-Q#{quarter_of(date.month)}"
  def label(%Date{} = date, :year), do: "#{date.year}"

  def label(%Date{} = date, :hour) do
    # Without a time component we can only bucket to the day; fall back.
    Date.to_iso8601(date)
  end

  def label(%Date{} = date, :minute), do: Date.to_iso8601(date)

  defp quarter_of(month) when month in 1..3, do: 1
  defp quarter_of(month) when month in 4..6, do: 2
  defp quarter_of(month) when month in 7..9, do: 3
  defp quarter_of(_month), do: 4

  defp pad2(int) when int < 10, do: "0#{int}"
  defp pad2(int), do: to_string(int)

  defp postgres_unit(:minute), do: "minute"
  defp postgres_unit(:hour), do: "hour"
  defp postgres_unit(:day), do: "day"
  defp postgres_unit(:week), do: "week"
  defp postgres_unit(:month), do: "month"
  defp postgres_unit(:quarter), do: "quarter"
  defp postgres_unit(:year), do: "year"
end
