defmodule AshDynal.Error do
  @moduledoc """
  Error type raised/returned by AshDynal.

  Errors are structured so callers can pattern-match and so validation errors
  name the offending field/function rather than just saying "invalid request".
  """

  defexception [:message, :field, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          field: atom() | nil,
          reason: atom() | nil
        }

  def exception(message) when is_binary(message), do: %__MODULE__{message: message}
  def exception(%__MODULE__{} = error), do: error

  def exception(opts) when is_map(opts) or is_list(opts) do
    get = fn key ->
      if is_map(opts), do: Map.get(opts, key), else: Keyword.get(opts, key)
    end

    field = get.(:field)
    reason = get.(:reason)
    message = get.(:message) || default_message(field, reason)
    %__MODULE__{message: message, field: field, reason: reason}
  end

  defp default_message(nil, nil), do: "invalid AshDynal request"
  defp default_message(field, nil), do: "invalid AshDynal request: #{inspect(field)}"

  defp default_message(field, reason),
    do: "invalid AshDynal request: #{inspect(field)} (#{reason})"

  defimpl String.Chars do
    def to_string(%{message: message}), do: message
  end
end
