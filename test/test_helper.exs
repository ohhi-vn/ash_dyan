ExUnit.start()

# The Postgres integration tests require a running Postgres instance and are
# excluded by default. Enable them with `RUN_POSTGRES=1 mix test`.
if System.get_env("RUN_POSTGRES") == "1" do
  ExUnit.configure(exclude: [])
else
  ExUnit.configure(exclude: [:postgres])
end

# Compile the in-memory (Simple data layer) support modules. The resource
# must be required before the domain that references it, because the domain's
# `dyan` verifier checks that each `analyzable_resource` is a compiled Ash
# resource at compile time.
Code.require_file("support/order.ex", __DIR__)
Code.require_file("support/shop.ex", __DIR__)
Code.require_file("support/plain_resource.ex", __DIR__)
Code.require_file("support/seed.ex", __DIR__)

if System.get_env("RUN_POSTGRES") == "1" do
  Code.require_file("support/repo.ex", __DIR__)
  Code.require_file("support/postgres_order.ex", __DIR__)
end
