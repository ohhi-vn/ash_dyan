ExUnit.start()

# The Postgres integration tests require a running Postgres instance and are
# excluded by default. Enable them with `RUN_POSTGRES=1 mix test`.
if System.get_env("RUN_POSTGRES") == "1" do
  ExUnit.configure(exclude: [])
else
  ExUnit.configure(exclude: [:postgres])
end

# Compile the in-memory (Simple data layer) support modules. A resource's Ash
# verification reads its `domain:` DSL config at compile time, so the domain
# (Shop) must be required BEFORE the resources that reference it. When Postgres
# tests are enabled, the Postgres repo/resource must also be required before
# Shop so Shop's `resources` block (which conditionally includes PostgresOrder)
# verifies against an already-compiled module.
if System.get_env("RUN_POSTGRES") == "1" do
  Code.require_file("support/repo.ex", __DIR__)
  Code.require_file("support/postgres_order.ex", __DIR__)
end

Code.require_file("support/shop.ex", __DIR__)
Code.require_file("support/order.ex", __DIR__)
Code.require_file("support/plain_resource.ex", __DIR__)
Code.require_file("support/seed.ex", __DIR__)
