# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-10

### Added

- Initial release of AshDyan.
- `dyan` DSL extension for declaring analyzable fields on Ash resources.
- Domain-level `dyan` registry via `AshDyan.Domain`.
- Runtime analysis engine (`AshDyan.run/1,2`) supporting:
  - frequency / group-by counts
  - numeric aggregates (sum, avg, min, max, count, count_distinct, stddev, variance, median)
  - time bucketing
  - percentiles
  - histograms
- In-memory aggregation bounded by `max_limit`, `max_group_by`, and `query_timeout`.
- Capability check API (`AshDyan.supports?/2`) for data-layer limits.
- Structured errors via `AshDyan.Error` with stable `reason` atoms.
- Chart adapter (`AshDyan.Charts.to_chartjs/1`).
- Documentation guides (`guides/usage.md`, `guides/design.md`).

### Changed

- Removed the shipped Phoenix/Channel/gen_api adapter modules
  (`AshDyan.Adapters.*`). AshDyan is now fully standalone — no `plug`
  dependency at compile time. Delivery layers are documented as copy-paste
  snippets (see README "Building an adapter") rather than versioned APIs.
- `:sum` now rejects `nil` values before reducing (matching every other
  aggregate), so a column with a `nil` no longer raises `ArithmeticError`.
- `AshDyan.Engine.apply_filters/2` documents that filters are parsed internally
  via `Ash.Filter.parse/2` (not `filter_input`) so the `dyan` whitelist stays
  the security boundary.
- `AshDyan.Info.analyzable_field/3` typespec now includes `:histogram`.
