# Usage Guide

This guide walks through declaring an Ash resource as analyzable and running
dynamic analyses against it at runtime.

## 1. Declare a resource as analyzable

Add `AshDyan` to the resource's extensions and open a `dynal` section. Each
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

  dynal do
    # Count occurrences of a categorical column.
    analyzable_field :status, type: :frequency

    # Numeric aggregates over a column.
    analyzable_field :total_amount, type: :aggregate,
      functions: [:sum, :avg, :min, :max]

    # Time-bucketed aggregates (in-memory bucketing on any data layer).
    analyzable_field :inserted_at, type: :time_bucket,
      buckets: [:day, :week, :month]

    # In-memory percentiles.
    analyzable_field :total_amount, type: :percentile,
      percentiles: [50, 90, 99]

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
| `type`        | all                       | `:frequency` / `:aggregate` / `:time_bucket` / `:percentile` |
| `functions`   | `:aggregate`              | Allowed aggregate functions.                |
| `buckets`     | `:time_bucket`            | Allowed bucket granularities.              |
| `percentiles` | `:percentile`            | Allowed percentile values.                 |
| `time_field`  | `:time_bucket`            | Time attribute to bucket on (defaults to `name`). |

## 2. (Optional) Register resources on a domain

The domain `dynal` section is a thin discovery registry. Cross-resource joins are
out of scope for v1.

```elixir
defmodule MyApp.Shop do
  use Ash.Domain, extensions: [AshDyan.Domain]

  dynal do
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
| `type`         | always                                | One of the four capabilities.                   |
| `column`       | `:frequency` / `:aggregate` / `:percentile` | The metric/attribute to analyze.           |
| `function`     | `:aggregate`                          | One of the whitelisted functions.              |
| `bucket`       | `:time_bucket`                        | One of the whitelisted buckets.                |
| `time_field`   | `:time_bucket`                        | Defaults to `column`.                         |
| `percentiles`  | `:percentile`                         | List of whitelisted percentile values.         |
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
`:bad_type`, `:invalid_value`, `:unsupported_data_layer`,
`:no_primary_read_action`.

## 7. Capability checks

Before issuing a query, you can discover data-layer limits:

```elixir
AshDyan.supports?(MyApp.Order, :percentile)
# => true on Postgres, false on the in-memory Simple layer (v1)
```

## 8. Adapters (reference)

Thin, optional adapters translate external requests into `AshDyan.run/2`:

- `AshDyan.Adapters.PhoenixController.analyze/2` — render JSON from controller params.
- `AshDyan.Adapters.PhoenixChannel.analyze/3` — reply to a channel event.
- `AshDyan.Adapters.GenApiBridge.run/2` — MFA bridge for `ash_phoenix_gen_api`.

## 9. Logging

`AshDyan.run/2` emits structured `Logger` events:

- `:debug` when a request starts or is rejected during validation/configuration.
- `:warning` when the requested analysis type is unsupported by the data layer.
- `:error` when the underlying read fails.

Filter contents are never logged.

## 10. Analysis types supported

AshDyan exposes four analysis capabilities. Each must be whitelisted per field
in the resource's `dynal` section (see §1) and is gated by the resource's data
layer (see §7).

| Type           | What it computes                                              | Required request fields                          | `group_by` |
| -------------- | ------------------------------------------------------------- | ------------------------------------------------ | ---------- |
| `:frequency`   | Count of occurrences of a categorical column.                 | `column`                                         | optional   |
| `:aggregate`   | Numeric aggregate of a column (`sum`/`avg`/`min`/`max`).      | `column`, `function`                             | optional   |
| `:time_bucket` | Time-bucketed aggregate of a column over a time field.        | `time_field` (or `column`), `bucket`, `function` | optional   |
| `:percentile`  | In-memory percentile(s) of a numeric column.                  | `column`, `percentiles`                          | optional   |

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

### Data-layer capability matrix

Not every data layer can serve every type. `AshDyan.supports?/2` (§7) reflects
this matrix; a request for an unsupported type returns
`{:error, %AshDyan.Error{field: :type, reason: :unsupported_data_layer}}`.

| Data layer                       | `:frequency` | `:aggregate` | `:time_bucket` | `:percentile` |
| -------------------------------- | ------------ | ------------ | -------------- | ------------- |
| `AshPostgres`                    | yes          | yes          | yes            | yes           |
| `Ash.DataLayer.Simple` (ETS)     | yes          | yes          | yes            | no (v1)       |
| Other / unknown (Default)        | yes          | yes          | no             | no            |

- **Postgres** — all four capabilities are supported.
- **Simple (ETS, in-memory)** — `:frequency`, `:aggregate`, and `:time_bucket`
  are computed in memory; `:percentile` is rejected by policy in v1.
- **Default (any other layer)** — only the universally-safe `:frequency` and
  `:aggregate` are allowed; `:time_bucket` and `:percentile` are rejected with a
  clear error rather than silently wrong results.

## 11. Limitations

v1 is intentionally scoped. Known limitations:

- **No cross-resource joins.** The domain `dynal` registry (§2) is discovery-only;
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
  buckets, percentiles, and filter targets declared in the `dynal` section.
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
