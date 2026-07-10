defmodule AshDyan.Adapters.GenApiBridge do
  @moduledoc """
  A small MFA-based bridge for exposing AshDyan through `ash_phoenix_gen_api`.

  `ash_phoenix_gen_api` generates runtime API surfaces from Ash resources. This
  module provides a stable `{module, function, args}` entry point so a generated
  API can route a generic analysis call to `AshDyan.run/2` without AshDyan
  depending on `ash_phoenix_gen_api`.

  ## Example

  In your gen_api configuration, point the analysis action at:

      {AshDyan.Adapters.GenApiBridge, :run, [:spec, :opts]}

  where `:spec` and `:opts` are supplied by the generated call.
  """

  @doc """
  Bridge entry point: runs an AshDyan request and returns the result.

  `spec` is a request map or `AshDyan.Request`. `opts` is a keyword list of
  `AshDyan.run/2` options (e.g. `actor:`, `tenant:`).
  """
  @spec run(map() | AshDyan.Request.t(), keyword()) ::
          {:ok, AshDyan.Result.t()} | {:error, term()}
  def run(spec, opts \\ []) when is_map(spec) or is_struct(spec) do
    AshDyan.run(spec, opts)
  end

  @doc """
  Like `run/2` but returns a JSON-encodable map (the result struct as a map).
  """
  def run_json(spec, opts \\ []) do
    case run(spec, opts) do
      {:ok, %AshDyan.Result{} = result} ->
        {:ok, Map.from_struct(result)}

      {:error, _} = error ->
        error
    end
  end
end
