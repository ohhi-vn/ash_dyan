ExUnit.start()

# Compile the in-memory (Simple data layer) support modules.
Code.require_file("support/order.ex", __DIR__)
Code.require_file("support/plain_resource.ex", __DIR__)
Code.require_file("support/shop.ex", __DIR__)
Code.require_file("support/seed.ex", __DIR__)

# The Postgres path is optional: it requires `ash_postgres` and a running DB.
# Enable with `RUN_POSTGRES=1 mix test`.
if System.get_env("RUN_POSTGRES") == "1" do
  Code.require_file("support/repo.ex", __DIR__)
  Code.require_file("support/postgres_order.ex", __DIR__)
end
