# AshDyan

> **Note:** This library is under active development, unstable and the API may change.

Runtime-driven dynamic analysis for any Ash resource. Turn "give me a chart of X
grouped by Y, filtered by Z" into a generic, safe, reusable runtime capability —
instead of writing a bespoke aggregate action per chart.

AshDyan is a **standalone Ash extension** with no dependency on
`ash_phoenix_gen_api`. It works on any Ash app, Phoenix or not. It is **not** a
full BI/reporting engine, not a query builder UI, and not tied to
Phoenix/Channels. Delivery (HTTP controller, Channel, LiveView, gen_api mfa) is a
thin adapter on top.

## Installation

```elixir
def deps do
  [
    {:ash_dyan, "~> 0.1.0"}
  ]
end
```

## Security model

The `dyan` DSL is a **whitelist**. The runtime request can only reference
fields, functions, buckets, and filter targets declared there — this is what
makes "arbitrary column + arbitrary filter from the client" safe rather than an
injection/DoS vector. Queries run through the resource's normal read action, so
Ash policies/authorization apply unchanged. There is no "skip policies" mode.

## Declaring a resource analyzable

```elixir
defmodule MyApp.Order do
  use Ash.Resource,
    extensions: [AshDyan]

  dyan do
    analyzable_field :status, type: :frequency
    analyzable_field :total_amount, type: :aggregate, functions: [:sum, :avg, :min, :max, :count, :count_distinct, :stddev, :variance, :median]
    analyzable_field :inserted_at, type: :time_bucket, buckets: [:day, :week, :month]
    analyzable_field :total_amount, type: :percentile, percentiles: [50, 90, 99]
    analyzable_field :total_amount, type: :histogram, bins: 10

    max_group_by 3
    default_limit 100
    max_limit 1000
    allow_filters_on [:status, :region, :inserted_at]
  end
end
```

A domain-level declaration is a thin registry for discovery (cross-resource
joins are out of scope for v1):

```elixir
defmodule MyApp.Shop do
  use Ash.Domain, extensions: [AshDyan.Domain]

  dyan do
    analyzable_resource MyApp.Order
  end
end
```

## Runtime request

```elixir
%{
  domain: MyApp.Shop,
  resource: MyApp.Order,
  type: :time_bucket,          # :frequency | :aggregate | :time_bucket | :percentile | :histogram
  column: :total_amount,
  function: :sum,               # required for :aggregate
  bucket: :day,                 # required for :time_bucket
  time_field: :inserted_at,
  group_by: [:status],          # optional, checked against max_group_by
  percentiles: [50, 90],        # required for :percentile
  bins: 10,                     # optional for :histogram (default 10)
  bin_width: nil,               # optional for :histogram (auto-computed if nil)
  filters: %{status: "paid", region: ["EU", "US"]},
  limit: 200
}
```

Run it:

```elixir
{:ok, result} = AshDyan.run(spec)
# with an actor for policy checks:
{:ok, result} = AshDyan.run(spec, actor: current_user)
# with an explicit in-memory dataset (Ash.DataLayer.Simple / tests):
{:ok, result} = AshDyan.run(spec, data: rows)
# turn the result into a chart-library-ready shape:
chart = AshDyan.Charts.to_chartjs(result)
```

`AshDyan.run/1` (or `run/2` with an `actor`) is the single entry point. It:

1. Validates the spec against the resource's `dyan` DSL config (unknown
   column/function → error naming the offending field, not silently ignored).
2. Builds an `Ash.Query` selecting only the needed columns, applying the
   caller's filters and the configured `limit`.
3. Runs it through the resource's normal read action — so Ash policies apply.
4. Aggregates the result in memory into the stable chart shape.

## Output shape

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

Frequency and histogram outputs use the same `labels`/`series` shape so a
client-side chart adapter doesn't need per-type branching.

## How it works

`AshDyan.run/1` is the single entry point. It:

1. Validates the spec against the resource's `dyan` DSL config (unknown
   column/function → error naming the offending field, not silently ignored).
2. Builds an `Ash.Query` that selects only the needed columns, applies the
   caller's filters (via `filter_input`, which honors field policies) and the
   configured `limit`.
3. Runs it through the resource's normal read action — so Ash policies apply.
4. Aggregates the returned rows **in memory** into the stable chart shape.

### Why in-memory aggregation?

Ash's `Ash.Query` (3.x) does not expose a generic `group_by` builder, and the
return shape of grouped aggregates is data-layer dependent. To keep AshDyan
data-layer agnostic, safe, and predictable, the engine fetches only the columns
it needs (bounded by `max_limit`, a hard cap that prevents a full-cardinality
`group_by` from blowing up the DB) and aggregates in memory. This keeps the
security boundary (the `dyan` DSL whitelist + enforced limits) intact while
avoiding data-layer-specific query shapes. `TimeBucket.expr/2` is provided as a
reference for a future Postgres `date_trunc` pushdown.

## Capability notes & data-layer limits

| Capability            | Approach                                          | Data-layer dependency               |
| --------------------- | ------------------------------------------------- | ------------------------------------ |
| Frequency / group-by  | in-memory count after a filtered, limited read    | Any Ash data layer                   |
| Numeric aggregates    | in-memory sum/avg/min/max/count/count_distinct/   | Any Ash data layer                   |
|                       | stddev/variance/median after a filtered read      |                                      |
| Time bucketing        | in-memory bucket label (Postgres `date_trunc` ref)| Any Ash data layer                   |
| Percentiles           | in-memory percentile computation                  | Any Ash data layer                   |
| Histogram             | in-memory binning of a numeric column             | Any Ash data layer                   |

All four capabilities therefore work on **any** Ash data layer. The capability
check (`AshDyan.supports?/2`) still surfaces data-layer limits explicitly so
callers can discover them before issuing a query — for example, a deployment
that wants to forbid percentiles on the in-memory `Ash.DataLayer.Simple` layer
can do so by configuring `AshDyan.DataLayer.Simple` to return `false` for
`:percentile`.

## Non-functional guarantees

- **Authorization**: runs through the resource's read action; Ash policies apply.
- **Resource limits**: `max_group_by`, `max_limit`, and a `query_timeout` are
  enforced. `query_timeout` is always applied to the underlying read (it
  defaults to the resource's configured `query_timeout` and can be overridden
  per call via `run(spec, timeout: ms)`).
- **Errors**: validation errors name the offending field/function and carry a
  stable `reason` atom for programmatic matching (see `AshDyan.Error`).
- **Logging**: `AshDyan.run/2` emits structured `Logger` events — `:debug`
  when a request starts or is rejected, `:warning` when the analysis type is
  unsupported by the data layer, and `:error` when the read fails. Filter
  contents are never logged.
- **Testability**: the engine is pure `run/1,2` functions testable against Ash
  resources without any web layer.

## Adapters (reference, not required)

- `AshDyan.Adapters.PhoenixController` — a thin controller action.
- `AshDyan.Adapters.PhoenixChannel` — a thin channel event handler.
- `AshDyan.Adapters.GenApiBridge` — an MFA bridge for `ash_phoenix_gen_api`.

## Milestones

- **M0** — DSL scaffolding: `dyan` section/entities, `Info` module, verifiers.
- **M1** — frequency + numeric aggregates, formatter, tests (ETS + Postgres-ready).
- **M2** — time bucketing with Postgres `date_trunc` and ETS fallback.
- **M3** — percentiles/histograms with capability-check API.
- **M4** — hardening: limits, timeouts, structured errors.
- **M5** — docs & adapters (this file + the adapters above).
