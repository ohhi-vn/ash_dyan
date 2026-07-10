defmodule AshDynal.Adapters.GenApiBridge do
  @moduledoc """
  A small MFA-based bridge for exposing AshDynal through `ash_phoenix_gen_api`.

  `ash_phoenix_gen_api` generates runtime API surfaces from Ash resources. This
  module provides a stable `{module, function, args}` entry point so a generated
  API can route a generic analysis call to `AshDynal.run/2` without AshDynal
  depending on `ash_phoenix_gen_api`.

  ## Example

  In your gen_api configuration, point the analysis action at:

      {AshDynal.Adapters.GenApiBridge, :run, [:spec, :opts]}

  where `:spec` and `:opts` are supplied by the generated call.
  """

  @doc """
  Bridge entry point: runs an AshDynal request and returns the result.

  `spec` is a request map or `AshDynal.Request`. `opts` is a keyword list of
  `AshDynal.run/2` options (e.g. `actor:`, `tenant:`).
  """
  @spec run(map() | AshDynal.Request.t(), keyword()) ::
          {:ok, AshDynal.Result.t()} | {:error, term()}
  def run(spec, opts \\ []) when is_map(spec) or is_struct(spec) do
    AshDynal.run(spec, opts)
  end

  @doc """
  Like `run/2` but returns a JSON-encodable map (the result struct as a map).
  """
  def run_json(spec, opts \\ []) do
    case run(spec, opts) do
      {:ok, %AshDynal.Result{} = result} ->
        {:ok, Map.from_struct(result)}

      {:error, _} = error ->
        error
    end
  end
end
