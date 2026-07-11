# Design & Architecture

This guide explains how AshDyan is structured and why it makes
"arbitrary column + arbitrary filter from the client" safe rather than an
injection / DoS vector.

## Goals

- Turn "give me a chart of X grouped by Y, filtered by Z" into a generic,
  safe, reusable runtime capability across **any** Ash resource — instead of
  writing a bespoke aggregate action per chart.
- Stay **data-layer agnostic**: the same engine works on `Ash.Postgres`,
  `Ash.DataLayer.Simple` (ETS), or any other layer.
- Keep Ash's **authorization** intact: every query runs through the resource's
  normal read action, so policies apply unchanged.
- Be a **standalone extension** with no dependency on `ash_phoenix_gen_api`
  or Phoenix. Delivery (HTTP controller, Channel, LiveView, gen_api MFA) is a
  thin adapter on top.

## High-level flow

```
request map / AshDyan.Request
        │
        ▼
   Request.normalize   ── fill defaults, coerce string keys
        │
        ▼
   Request.validate    ── check against the `dyan` whitelist
        │                        (field/function/bucket/percentile/group_by/filter/limit)
        ▼
   Engine.build_query ── resolve primary read action
        │                 └─ apply_select / apply_filters / apply_limit / apply_timeout
        ▼
   Engine.run_query   ── Ash.read through the resource's read action
        │                        (actor / tenant / data applied here)
        ▼
   Result.format      ── Engine.Formatter aggregates in memory
        │
        ▼
   %AshDyan.Result{type, labels, series}
```

`AshDyan.run/2` is the single entry point. It returns `{:ok, result}` or
`{:error, %AshDyan.Error{}}`; `run!/2` raises instead.

## The security model: a compile-time whitelist

The `dyan` DSL section is a **whitelist**. A runtime request can only
reference fields, functions, buckets, and filter targets declared there. This is
what makes dynamic requests safe:

- `analyzable_field` declarations are verified at compile time
  (`AshDyan.Dsl.Verifiers.ValidateAnalyzableFields`) — a field must reference
  a real attribute, and `:aggregate` / `:time_bucket` / `:percentile`
  declarations must declare at least one function / bucket / percentile.
- At runtime, `Request.validate/1` re-checks the request against that
  whitelist and names the offending `field` / `reason` on failure.
- `allow_filters_on` restricts which attributes a request may filter on. Filters
  are parsed as **internal** filters (so attributes need not be `public?`) and
  attached to the query — but only after passing the whitelist check.

Because the request never reaches a raw `Ash.Filter` parse until it has been
vetted against the whitelist, untrusted input cannot inject arbitrary filter
expressions or reference undeclared fields.

## Why in-memory aggregation?

Ash's `Ash.Query` (3.x) does not expose a generic `group_by` builder, and
the return shape of grouped aggregates is data-layer dependent. To keep AshDyan
data-layer agnostic, safe, and predictable, the engine:

1. selects **only** the columns it needs (metric column, time field, group_by
   fields, filter fields),
2. applies the caller's filters and the configured `limit` — a **hard cap**
   that prevents a full-cardinality `group_by` from blowing up the database,
3. runs the query through the resource's read action (so `Ash.Policy`
   authorization applies unchanged),
4. aggregates the returned rows **in memory** into the stable
   `labels` / `series` output shape.

This keeps the security boundary (whitelist + enforced limits) intact while
avoiding data-layer-specific query shapes.

### Capability gating

`AshDyan.supports?/2` surfaces data-layer limits explicitly so callers can
discover them *before* issuing a query:

- `AshDyan.DataLayer.Postgres` — all four capabilities supported.
- `AshDyan.DataLayer.Simple` (ETS) — `:frequency`, `:aggregate`,
  `:time_bucket` supported; `:percentile` rejected (clear error rather than
  silently wrong results).
- `AshDyan.DataLayer.Default` — only `:frequency` / `:aggregate`;
  `:time_bucket` / `:percentile` rejected.

The capability check is enforced in `Engine.build_query/2` (a `:warning` is
logged and an `:unsupported_data_layer` error is returned when the data layer
cannot serve the requested type).

## Module map

| Module                          | Responsibility                                              |
| ------------------------------- | ----------------------------------------------------------- |
| `AshDyan`                     | Public API (`run/2`, `run!/2`, `supports?/2`), logging.     |
| `AshDyan.Request`             | Normalize + validate a request against the `dyan` whitelist.  |
| `AshDyan.Engine`             | Build the `Ash.Query`, run it, enforce timeout/limits.         |
| `AshDyan.Engine.Formatter`   | In-memory aggregation into `labels` / `series`.                |
| `AshDyan.Engine.TimeBucket`  | In-memory bucket labels; `date_trunc` reference for pushdown. |
| `AshDyan.Result`             | The chart-ready output struct.                               |
| `AshDyan.Info`               | Read back the persisted `dyan` config for a resource.         |
| `AshDyan.Error`              | Structured error with `field` / `reason`.                    |
| `AshDyan.DataLayer.*`        | Per-data-layer capability behaviour.                         |
| `AshDyan.Dsl.*`             | DSL entity, transformer (persist config), verifiers.         |
| `AshDyan.Domain` / `Info`    | Optional domain-level resource registry.                       |
| Delivery adapters            | Not shipped. Write your own thin glue over `AshDyan.run/2`.    |

## Performance notes

- **Column selection** keeps the fetched row set minimal, bounding both the
  DB transfer and the in-memory work.
- **`max_limit`** is a hard ceiling on rows returned, which bounds the
  in-memory aggregation cost regardless of cardinality.
- **Formatter grouping** keys on stringified labels directly (via
  `to_label` / `group_name`), avoiding the O(n²) label→key scans of an
  earlier implementation. Grouping by the label string also makes the code
  robust to non-`Enumerable` attribute values (e.g. atoms).
- **Percentiles** are computed with linear interpolation between the two nearest
  ranks, for both `Decimal` and plain-number representations.

## Error handling

- Validation / configuration errors are structured `AshDyan.Error` values
  with a `field` and a stable `reason` atom (see the Usage Guide for the full
  list).
- A filter that passes the whitelist but still fails Ash's `Ash.Filter.parse`
  (e.g. a type mismatch) is surfaced as `:invalid_value` rather than
  silently dropped — dropping it would return a wider, incorrect result set.
- The `query_timeout` is **always** applied to the underlying read (defaulting
  to the resource's configured `query_timeout`, overridable per call). It is
  guarded by `Ash.DataLayer.data_layer_can?/2` so the in-memory ETS path
  still works.

## Limitations (v1)

- No cross-resource joins (the domain registry is discovery-only).
- In-memory aggregation means the result is bounded by `max_limit` rows; it is
  not a substitute for a true SQL `GROUP BY` pushdown (the `TimeBucket.expr/2`
  helper is a reference for a future Postgres `date_trunc` pushdown).
- `:percentile` is gated off on the ETS data layer by policy, even though the
  engine can compute it in memory.
