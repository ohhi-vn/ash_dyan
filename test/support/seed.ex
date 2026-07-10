defmodule AshDyan.Test.Seed do
  @moduledoc false

  alias AshDyan.Test.Order

  @doc """
  Build the in-memory dataset for tests as a list of resource structs.

  The `Ash.DataLayer.Simple` data layer does not persist; tests attach this data
  to a query via `Ash.DataLayer.Simple.set_data/2` before reading.
  """
  def order_rows do
    base = ~U[2026-07-01 10:00:00Z]

    [
      %Order{
        id: "00000000-0000-0000-0000-000000000001",
        status: :paid,
        region: :EU,
        total_amount: Decimal.new("100.0"),
        inserted_at: base
      },
      %Order{
        id: "00000000-0000-0000-0000-000000000002",
        status: :paid,
        region: :US,
        total_amount: Decimal.new("50.0"),
        inserted_at: shift(base, 1)
      },
      %Order{
        id: "00000000-0000-0000-0000-000000000003",
        status: :refunded,
        region: :EU,
        total_amount: Decimal.new("20.0"),
        inserted_at: shift(base, 2)
      },
      %Order{
        id: "00000000-0000-0000-0000-000000000004",
        status: :paid,
        region: :APAC,
        total_amount: Decimal.new("200.0"),
        inserted_at: shift(base, 3)
      },
      %Order{
        id: "00000000-0000-0000-0000-000000000005",
        status: :pending,
        region: :US,
        total_amount: Decimal.new("10.0"),
        inserted_at: shift(base, 4)
      },
      %Order{
        id: "00000000-0000-0000-0000-000000000006",
        status: :paid,
        region: :EU,
        total_amount: Decimal.new("30.0"),
        inserted_at: shift(base, 5)
      }
    ]
  end

  defp shift(%DateTime{} = dt, days) do
    DateTime.add(dt, days * 24 * 60 * 60, :second)
  end
end
