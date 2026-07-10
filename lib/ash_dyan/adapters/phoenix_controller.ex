defmodule AshDyan.Adapters.PhoenixController do
  @moduledoc """
  A thin Phoenix controller adapter for AshDyan.

  This is intentionally minimal — AshDyan is not coupled to Phoenix. Drop this
  into a controller, or copy the body into your own. It translates controller
  params into an `AshDyan.Request`, runs it, and renders JSON.

  ## Example

      defmodule MyAppWeb.AnalysisController do
        use MyAppWeb, :controller
        alias AshDyan.Adapters.PhoenixController

        def analyze(conn, params) do
          PhoenixController.analyze(conn, params)
        end
      end
  """

  @doc """
  Run an analysis from controller params and render the result as JSON.

  Recognized params (all optional except `resource`/`type`):
  `domain`, `resource`, `type`, `column`, `function`, `bucket`, `time_field`,
  `group_by` (comma-separated or list), `percentiles` (comma-separated or list),
  `filters` (map), `limit`.
  """
  def analyze(conn, params) do
    spec = params_to_spec(params)

    opts =
      []
      |> then(fn o -> if actor = conn.assigns[:current_user], do: Keyword.put(o, :actor, actor), else: o end)
      |> then(fn o -> if tenant = conn.assigns[:tenant], do: Keyword.put(o, :tenant, tenant), else: o end)

    case AshDyan.run(spec, opts) do
      {:ok, result} ->
        render_json(conn, 200, result)

      {:error, %AshDyan.Error{} = error} ->
        render_json(conn, 422, %{error: error.message, field: error.field, reason: error.reason})

      {:error, other} ->
        render_json(conn, 500, %{error: inspect(other)})
    end
  end

  defp params_to_spec(params) do
    %{}
    |> put_atom(params, "domain")
    |> put_atom(params, "resource")
    |> put_atom(params, "type")
    |> put_atom(params, "column")
    |> put_atom(params, "function")
    |> put_atom(params, "bucket")
    |> put_atom(params, "time_field")
    |> put_list(params, "group_by")
    |> put_list(params, "percentiles")
    |> put_map(params, "filters")
    |> put_int(params, "limit")
  end

  defp put_atom(spec, params, key) do
    case Map.get(params, key) do
      nil -> spec
      value -> Map.put(spec, String.to_atom(key), to_atom(value))
    end
  end

  defp put_list(spec, params, key) do
    case Map.get(params, key) do
      nil -> spec
      value -> Map.put(spec, String.to_atom(key), to_list(value))
    end
  end

  defp put_map(spec, params, key) do
    case Map.get(params, key) do
      nil -> spec
      value when is_map(value) -> Map.put(spec, String.to_atom(key), value)
      _ -> spec
    end
  end

  defp put_int(spec, params, key) do
    case Map.get(params, key) do
      nil -> spec
      value -> Map.put(spec, String.to_atom(key), to_int(value))
    end
  end

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError ->
      raise AshDyan.Error,
        field: :spec,
        reason: :unknown_atom,
        message: "unrecognized value #{inspect(value)}"
  end

  defp to_atom(value), do: value

  defp to_list(value) when is_list(value), do: Enum.map(value, &to_atom/1)

  defp to_list(value) when is_binary(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.to_atom/1)

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)

  defp render_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
