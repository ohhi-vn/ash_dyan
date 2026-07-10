import Config

# In-memory data layer is the default for tests (no DB required).
config :ash_dynal, :ash_dynal, data_layer: Ash.DataLayer.Simple

# Postgres test repo — only used by the optional Postgres integration tests,
# which are excluded by default (they require a running Postgres + migrations).
config :ash_dynal, AshDynal.Test.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ash_dynal_test",
  port: 5432,
  pool: Ecto.Adapters.SQL.Sandbox

# Exclude Postgres integration tests unless explicitly enabled.
config :ash_dynal, :run_postgres_tests, false
