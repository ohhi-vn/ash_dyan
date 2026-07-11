defmodule AshDyan.PostgresIntegrationTest do
  @moduledoc """
  Optional Postgres integration tests.

  Run with `RUN_POSTGRES=1 mix test`. Requires `ash_postgres` and a running
  Postgres instance with migrations applied
  (`RUN_POSTGRES=1 mix ash_postgres.create && RUN_POSTGRES=1 mix ash_postgres.migrate`).
  """
  use ExUnit.Case, async: false

  alias AshDyan.Test.PostgresOrder

  @moduletag :postgres

  setup_all do
    :ok
  end

  test "frequency on Postgres" do
    {:ok, _} =
      Ash.Changeset.for_create(PostgresOrder, :create, %{
        status: :paid,
        region: :EU,
        total_amount: Decimal.new("100.0"),
        inserted_at: ~U[2026-07-01 10:00:00Z]
      })
      |> Ash.create()

    {:ok, result} =
      AshDyan.run(%{resource: PostgresOrder, type: :frequency, column: :status})

    assert result.type == :frequency
    assert "paid" in result.labels
  end

  test "percentile is supported on Postgres" do
    assert AshDyan.supports?(PostgresOrder, :percentile)
  end

  test "time_bucket uses date_trunc on Postgres" do
    {:ok, result} =
      AshDyan.run(%{
        resource: PostgresOrder,
        type: :time_bucket,
        time_field: :inserted_at,
        bucket: :day,
        function: :sum,
        column: :total_amount
      })

    assert result.type == :time_bucket
  end
end
