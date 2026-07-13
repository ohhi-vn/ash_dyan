# Usage Guide

This guide walks through declaring an Ash resource as analyzable and running
dynamic analyses against it at runtime.

## 1. Declare a resource as analyzable

Add `AshDyan` to the resource's extensions and open a `dyan` section. Each
`analyzable_field` is a **whitelist entry**: a runtime request may only reference
fields, functions, buckets, and percentiles declared here.

```elixir
defmodule MyApp.Order do
  use Ash.Resource,
    extensions: [AshDyan]

  attributes do
    uuid_primary_key :id
    attribute :status, :atom
    attribute :total_amount, :decimal
    attribute :region, :atom
    attribute :inserted_at, :utc_datetime
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  dyan do
    # Count occurrences of a categorical column.
    analyzable_field :status, type: :frequency

    # Numeric aggregates over a column.
    analyzable_field :total_amount, type: :aggregate,
      functions: [:sum, :avg, :min, :max, :count, :count_distinct, :stddev, :variance, :median]

    # Time-bucketed aggregates (in-memory bucketing on any data layer).
    analyzable_field :inserted_at, type: :time_bucket,
      buckets: [:day, :week, :month]

    # In-memory percentiles.
    analyzable_field :total_amount, type: :percentile,
      percentiles: [50, 90, 99]

    # Numeric distribution into bins (histogram).
    analyzable_field :total_amount, type: :histogram, bins: 10

    # Limits & guards.
    max_group_by 3
    default_limit 100
    max_limit 1000
    query_timeout 15_000
    allow_filters_on [:status, :region, :inserted_at]
  end
end
```

### Section options

| Option             | Default | Meaning                                                        |
| ------------------ | ------- | --------------------------------------------------------------- |
| `max_group_by`     | `3`     | Maximum number of `group_by` fields a request may specify.        |
| `default_limit`    | `100`   | Row limit applied when a request does not specify one.            |
| `max_limit`        | `1000`  | Hard cap on the `limit` a request may specify.                  |
| `query_timeout`    | `15000` | Per-request read timeout in milliseconds (always enforced).     |
| `allow_filters_on` | `[]`    | Attributes a runtime request is allowed to filter on.           |

### `analyzable_field` options

| Option        | Applies to                | Meaning                                  |
| ------------- | ------------------------- | ---------------------------------------- |
| `type`        | all                       | `:frequency` / `:aggregate` / `:time_bucket` / `:percentile` / `:histogram` |
| `functions`   | `:aggregate`              | Allowed aggregate functions: `:sum`, `:avg`, `:min`, `:max`, `:count`, `:count_distinct`, `:stddev`, `:variance`, `:median`. |
| `buckets`     | `:time_bucket`            | Allowed bucket granularities.              |
| `percentiles` | `:percentile`            | Allowed percentile values.                 |
| `time_field`  | `:time_bucket`            | Time attribute to bucket on (defaults to `name`). |
| `bins`        | `:histogram`              | Number of bins (default 10).                |
| `bin_width`   | `:histogram`              | Fixed bin width; auto-computed from the data range when omitted. |

## 2. (Optional) Register resources on a domain

The domain `dyan` section is a thin discovery registry. Cross-resource joins are
out of scope for v1.

```elixir
defmodule MyApp.Shop do
  use Ash.Domain, extensions: [AshDyan.Domain]

  dyan do
    analyzable_resource MyApp.Order
  end
end
```

## 3. Build a request

A request is a map (or an `AshDyan.Request` struct). String keys are accepted
so HTTP adapters can pass params through directly.

```elixir
spec = %{
  domain: MyApp.Shop,
  resource: MyApp.Order,
  type: :time_bucket,
  time_field: :inserted_at,
  bucket: :day,
  column: :total_amount,
  function: :sum,
  group_by: [:status],
  filters: %{region: :EU},
  limit: 200
}
```

| Field          | Required when                          | Notes                                         |
| -------------- | -------------------------------------- | --------------------------------------------- |
| `resource`     | always                                | Must be an analyzable Ash resource.            |
| `domain`       | recommended                           | Used to resolve the read action.               |
| `type`         | always                                | One of the five capabilities.                   |
| `column`       | `:frequency` / `:aggregate` / `:percentile` / `:histogram` | The metric/attribute to analyze.           |
| `function`     | `:aggregate`                          | One of the whitelisted functions.              |
| `bucket`       | `:time_bucket`                        | One of the whitelisted buckets.                |
| `time_field`   | `:time_bucket`                        | Defaults to `column`.                         |
| `percentiles`  | `:percentile`                         | List of whitelisted percentile values.         |
| `bins`         | `:histogram`                          | Number of bins (default 10).                   |
| `bin_width`    | `:histogram`                          | Fixed bin width; auto-computed when omitted.   |
| `group_by`     | optional                               | Checked against `max_group_by`.               |
| `filters`      | optional                               | Only `allow_filters_on` fields are permitted. |
| `limit`        | optional                               | Capped at `max_limit`.                       |

## 4. Run it

```elixir
# Safe: returns {:ok, result} or {:error, %AshDyan.Error{}}.
{:ok, result} = AshDyan.run(spec)

# With an actor for policy checks:
{:ok, result} = AshDyan.run(spec, actor: current_user)

# With a tenant:
{:ok, result} = AshDyan.run(spec, tenant: "acme")

# Override the per-request timeout (defaults to the resource's query_timeout):
{:ok, result} = AshDyan.run(spec, timeout: 5_000)

# Raise on error instead:
result = AshDyan.run!(spec)
```

### Options

- `:actor` — the actor passed to the read action for policy checks.
- `:tenant` — tenant for multitenant resources.
- `:timeout` — overrides the per-request query timeout (defaults to the
  resource's `query_timeout`, which is always enforced).
- `:data` — explicit in-memory dataset for the `Ash.DataLayer.Simple` layer
  (used by tests and embedded resources).

## 5. Read the result

Every analysis type returns the same `labels` / `series` shape, so a client-side
chart adapter needs no per-type branching.

```elixir
%AshDyan.Result{
  type: :time_bucket,
  labels: ["2026-07-01", "2026-07-02", ...],
  series: [
    %{name: "paid", data: [120.5, 98.0, ...]},
    %{name: "refunded", data: [12.0, 4.5, ...]}
  ]
}
```

- `:frequency` — `labels` are distinct column values; one series (named after the
  column) with counts, or one series per `group_by` combination.
- `:aggregate` — `labels` is `[column]` (no group_by) or the distinct group
  combinations; one series named after the function.
- `:time_bucket` — `labels` are bucket labels; series per group_by combination
  (or a single series named after the function).
- `:percentile` — `labels` are percentile labels (`"50th"`, ...); series per
  group_by combination (or a single series named after the column).
- `:histogram` — `labels` are bin ranges (`"0.0-50.0"`, ...); series per group_by
  combination (or a single series named after the column). Counts are aligned to
  the shared bin axis so a chart adapter needs no per-type branching.

## 6. Errors

Validation and configuration errors are returned as
`{:error, %AshDyan.Error{field:, reason:}}` naming the offending field. The
`reason` atom is stable for programmatic matching:

```elixir
case AshDyan.run(spec) do
  {:ok, result} -> render(result)
  {:error, %AshDyan.Error{field: :limit, reason: :too_large}} ->
    {:error, 422, "limit exceeds maximum"}
end
```

Common reasons: `:not_a_resource`, `:not_analyzable`, `:unknown_type`,
`:not_analyzable` (column/time_field), `:not_allowed` (function/bucket/
percentiles/filters), `:too_many`, `:too_large`, `:unknown_attribute`,
`:bad_type`, `:bad_bins`, `:invalid_value`, `:unsupported_data_layer`,
`:no_primary_read_action`, `:not_supported`, `:incompatible`.

## 7. Capability checks

Before issuing a query, you can discover data-layer limits:

```elixir
AshDyan.supports?(MyApp.Order, :percentile)
# => true on Postgres, false on the in-memory Simple layer (v1)
```

## 8. Building an adapter

AshDyan ships **no** Phoenix/Channel/gen_api modules. The `run/2` contract is
already adapter-agnostic, so a delivery layer is ~10 lines of glue you own. A
thin Phoenix controller action looks like:

```elixir
defmodule MyAppWeb.AnalysisController do
  use MyAppWeb, :controller

  def analyze(conn, params) do
    spec = %{
      domain: String.to_atom(params["domain"]),
      resource: String.to_atom(params["resource"]),
      type: String.to_atom(params["type"]),
      column: maybe_atom(params["column"]),
      function: maybe_atom(params["function"]),
      bucket: maybe_atom(params["bucket"]),
      time_field: maybe_atom(params["time_field"]),
      group_by: maybe_atoms(params["group_by"]),
      percentiles: maybe_ints(params["percentiles"]),
      filters: params["filters"] || %{},
      limit: maybe_int(params["limit"])
    }

    opts = if actor = conn.assigns[:current_user], do: [actor: actor], else: []

    case AshDyan.run(spec, opts) do
      {:ok, result} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
      {:error, %AshDyan.Error{} = error} ->
        conn |> put_resp_content_type("application/json")
             |> send_resp(422, Jason.encode!(%{error: error.message, field: error.field, reason: error.reason}))
      {:error, other} ->
        conn |> put_resp_content_type("application/json") |> send_resp(500, Jason.encode!(%{error: inspect(other)}))
    end
  end
end
```

The same shape works for a Phoenix Channel (`handle_in("analyze", payload,
socket)` → `AshDyan.run(payload, opts)` → `{:reply, ...}`) or an
`ash_phoenix_gen_api` MFA bridge (`{MyApp.Analysis, :run, [:spec, :opts]}`).

## 9. Logging

`AshDyan.run/2` emits structured `Logger` events:

- `:debug` when a request starts or is rejected during validation/configuration.
- `:warning` when the requested analysis type is unsupported by the data layer.
- `:error` when the underlying read fails.

Filter contents are never logged.

## 10. Analysis types supported

AshDyan exposes five analysis capabilities. Each must be whitelisted per field
in the resource's `dyan` section (see §1) and is gated by the resource's data
layer (see §7).

| Type           | What it computes                                              | Required request fields                          | `group_by` |
| -------------- | ------------------------------------------------------------- | ------------------------------------------------ | ---------- |
| `:frequency`   | Count of occurrences of a categorical column.                 | `column`                                         | optional   |
| `:aggregate`   | Numeric aggregate of a column (`sum`/`avg`/`min`/`max`).      | `column`, `function`                             | optional   |
| `:time_bucket` | Time-bucketed aggregate of a column over a time field.        | `time_field` (or `column`), `bucket`, `function` | optional   |
| `:percentile`  | In-memory percentile(s) of a numeric column.                  | `column`, `percentiles`                          | optional   |
| `:histogram`   | Numeric distribution of a column into bins.                   | `column`, `bins` (optional), `bin_width` (optional) | optional   |

- **`:frequency`** — `labels` are the distinct column values; one series named
  after the column (or one series per `group_by` combination).
- **`:aggregate`** — `labels` is `[column]` with no `group_by`, or the distinct
  `group_by` combinations; one series named after the function.
- **`:time_bucket`** — `labels` are bucket labels (`day` → `2026-07-01`,
  `week` → Monday of the ISO week, `month` → `2026-07`, `quarter` → `2026-Q3`,
  `year` → `2026`, `hour`/`minute` → `YYYY-MM-DD HH:00`); series per `group_by`
  combination (or a single series named after the function).
- **`:percentile`** — `labels` are percentile labels (`"50th"`, ...); series
  per `group_by` combination (or a single series named after the column).
  Computed with linear interpolation between the two nearest ranks, for both
  `Decimal` and plain-number values.
- **`:histogram`** — `labels` are bin ranges (`"0.0-50.0"`, ...); series per
  `group_by` combination (or a single series named after the column). Counts are
  aligned to the shared bin axis so a chart adapter needs no per-type branching.
  Bins are computed from `bins`/`bin_width` (or auto-sized from the data range).

### Data-layer capability matrix

Not every data layer can serve every type. `AshDyan.supports?/2` (§7) reflects
this matrix; a request for an unsupported type returns
`{:error, %AshDyan.Error{field: :type, reason: :unsupported_data_layer}}`.

| Data layer                       | `:frequency` | `:aggregate` | `:time_bucket` | `:percentile` | `:histogram` |
| -------------------------------- | ------------ | ------------ | -------------- | ------------- | ------------ |
| `AshPostgres`                    | yes          | yes          | yes            | yes           | yes          |
| `Ash.DataLayer.Simple` (ETS)     | yes          | yes          | yes            | no (v1)       | yes          |
| Other / unknown (Default)        | yes          | yes          | no             | no            | no           |

- **Postgres** — all five capabilities are supported.
- **Simple (ETS, in-memory)** — `:frequency`, `:aggregate`, `:time_bucket`, and
  `:histogram` are computed in memory; `:percentile` is rejected by policy in v1.
- **Default (any other layer)** — only the universally-safe `:frequency` and
  `:aggregate` are allowed; `:time_bucket`, `:percentile`, and `:histogram` are
  rejected with a clear error rather than silently wrong results.

## 11. Chart-ready output (AshDyan.Charts)

Every analysis type returns the same `labels`/`series` shape. The `AshDyan.Charts`
module turns a result into chart-library-ready shapes so a client can render a
chart without knowing AshDyan's internals.

```elixir
{:ok, result} = AshDyan.run(spec)

# Pick a sensible default chart type from the result shape.
AshDyan.Charts.recommend(result)
# => :bar | :line | :area | :pie | :donut | :histogram | :scatter

# Serialize for a specific library (both return JSON-encodable maps).
AshDyan.Charts.to_chartjs(result)        # Chart.js `data`/`options`
AshDyan.Charts.to_echarts(result)        # ECharts `option`

# Or force a chart type:
AshDyan.Charts.to_chartjs(result, :line)
```

`recommend/1` maps result types to chart types:

| Result `type`   | Default chart (`recommend/1`) |
| --------------- | ------------------------------ |
| `:frequency`    | `:bar` (`:pie` for a single series) |
| `:aggregate`    | `:bar` (`:pie` for a single series) |
| `:time_bucket`  | `:line`                        |
| `:percentile`   | `:line`                        |
| `:histogram`    | `:histogram`                   |

The serialized maps are plain (JSON-encodable) structures: `to_chartjs/2` returns
`%{type:, data: %{labels:, datasets:}, options:}` and `to_echarts/2` returns an
ECharts `option` map (`%{tooltip:, legend:, xAxis:, yAxis:, series:}`).

## 12. Limitations

v1 is intentionally scoped. Known limitations:

- **No cross-resource joins.** The domain `dyan` registry (§2) is discovery-only;
  analyses run against a single resource.
- **In-memory aggregation.** The engine selects only the needed columns, applies
  the caller's filters and the configured `limit` (a hard cap), runs the query
  through the resource's read action, then aggregates the returned rows **in
  memory**. This is bounded by `max_limit` rows and is **not** a true SQL
  `GROUP BY` pushdown. `AshDyan.Engine.TimeBucket.expr/2` is a reference helper
  for a future Postgres `date_trunc` pushdown; today all bucketing is done in
  memory so behaviour is identical across data layers.
- **`:percentile` on ETS.** Although the engine can compute percentiles in
  memory, `:percentile` is gated off on the `Ash.DataLayer.Simple` layer by
  policy in v1 (returns `:unsupported_data_layer`).
- **`query_timeout` is data-layer dependent.** The timeout is always applied on
  data layers that can honor it (Postgres, etc.); on the in-memory ETS path it is
  skipped (guarded by `Ash.DataLayer.data_layer_can?/2`) so tests and embedded
  resources keep working.
- **Whitelist-only fields.** A request may only reference fields, functions,
  buckets, percentiles, and filter targets declared in the `dyan` section.
  Anything else is rejected during validation with a stable `reason` atom (§6).
- **Filters are restricted and internal.** Only `allow_filters_on` attributes may
  be filtered, and they are parsed as internal Ash filters (so they need not be
  `public?`). A filter that passes the whitelist but still fails Ash's filter
  parse (e.g. a type mismatch) surfaces as `:invalid_value` rather than being
  dropped.
- **`group_by` bounds.** The number of `group_by` fields is capped by
  `max_group_by`; referencing a non-existent attribute is rejected with
  `:unknown_attribute`.
- **No query-builder UI / BI engine.** AshDyan turns "chart of X grouped by Y,
  filtered by Z" into a safe runtime capability; it is not a full reporting tool
  or tied to Phoenix/Channels (those are thin adapters, §8).
