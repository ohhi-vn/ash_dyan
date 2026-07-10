import Config

# In-memory data layer is the default for tests (no DB required).
config :ash_dyan, :ash_dyan, data_layer: Ash.DataLayer.Simple

# Postgres test repo — only used by the optional Postgres integration tests,
# which are excluded by default (they require a running Postgres + migrations).
config :ash_dyan, AshDyan.Test.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ash_dyan_test",
  port: 5432,
  pool: Ecto.Adapters.SQL.Sandbox

# Exclude Postgres integration tests unless explicitly enabled.
config :ash_dyan, :run_postgres_tests, false
