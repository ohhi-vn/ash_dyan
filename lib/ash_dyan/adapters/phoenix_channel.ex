defmodule AshDyan.Adapters.PhoenixChannel do
  @moduledoc """
  A thin Phoenix Channel adapter for AshDyan.

  AshDyan is not coupled to Phoenix; this is provided as a reference adapter.
  Handle an incoming `"analyze"` event with the request spec as the payload.

  ## Example

      def handle_in("analyze", payload, socket) do
        AshDyan.Adapters.PhoenixChannel.analyze(socket, payload)
      end
  """

  @doc """
  Run an analysis from a channel payload and reply with the result.

  The socket's `:user` assign (if present) is used as the Ash actor, and
  `:tenant` (if present) as the tenant.
  """
  def analyze(socket, payload) when is_map(payload) do
    opts =
      []
      |> then(fn o -> if actor = Map.get(socket.assigns, :user), do: Keyword.put(o, :actor, actor), else: o end)
      |> then(fn o -> if tenant = Map.get(socket.assigns, :tenant), do: Keyword.put(o, :tenant, tenant), else: o end)

    case AshDyan.run(payload, opts) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, %AshDyan.Error{} = error} ->
        {:reply, {:error, %{error: error.message, field: error.field, reason: error.reason}},
         socket}

      {:error, other} ->
        {:reply, {:error, %{error: inspect(other)}}, socket}
    end
  end
end
