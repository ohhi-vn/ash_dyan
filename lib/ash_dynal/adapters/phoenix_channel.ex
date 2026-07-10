defmodule AshDynal.Adapters.PhoenixChannel do
  @moduledoc """
  A thin Phoenix Channel adapter for AshDynal.

  AshDynal is not coupled to Phoenix; this is provided as a reference adapter.
  Handle an incoming `"analyze"` event with the request spec as the payload.

  ## Example

      def handle_in("analyze", payload, socket) do
        AshDynal.Adapters.PhoenixChannel.analyze(socket, payload)
      end
  """

  @doc """
  Run an analysis from a channel payload and reply with the result.

  The socket's `:user` assign (if present) is used as the Ash actor, and
  `:tenant` (if present) as the tenant.
  """
  def analyze(socket, payload) when is_map(payload) do
    opts = []
    opts = if actor = Map.get(socket.assigns, :user), do: [actor: actor | opts], else: opts
    opts = if tenant = Map.get(socket.assigns, :tenant), do: [tenant: tenant | opts], else: opts

    case AshDynal.run(payload, opts) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}

      {:error, %AshDynal.Error{} = error} ->
        {:reply, {:error, %{error: error.message, field: error.field, reason: error.reason}},
         socket}

      {:error, other} ->
        {:reply, {:error, %{error: inspect(other)}}, socket}
    end
  end
end
