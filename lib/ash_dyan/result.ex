defmodule AshDyan.Result do
  @moduledoc """
  The chart-ready output shape returned by `AshDyan.run/1`.

  All analysis types share the same `labels`/`series` shape so a client-side
  chart adapter doesn't need per-type branching.

  ## Shape

      %AshDyan.Result{
        type: :time_bucket,
        labels: ["2026-07-01", "2026-07-02", ...],
        series: [
          %{name: "paid", data: [120.5, 98.0, ...]},
          %{name: "refunded", data: [12.0, 4.5, ...]}
        ]
      }
  """

  @type series :: %{name: String.t(), data: [term()]}
  @type t :: %__MODULE__{
          type: AshDyan.capability(),
          labels: [term()],
          series: [series()]
        }

  defstruct [:type, :labels, :series]

  @doc """
  Format raw Ash records into a `t/0`.

  The exact shaping depends on the request type and is delegated to the engine's
  formatter helpers.
  """
  @spec format(AshDyan.Request.t(), [Ash.Resource.Record.t()]) ::
          {:ok, t()} | {:error, term()}
  def format(request, records) do
    AshDyan.Engine.Formatter.format(request, records)
  end
end
