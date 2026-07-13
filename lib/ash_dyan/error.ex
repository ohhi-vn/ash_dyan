defmodule AshDyan.Error do
  @moduledoc """
  Error type raised/returned by AshDyan.

  Errors are structured so callers can pattern-match and so validation errors
  name the offending field/function rather than just saying "invalid request".

  ## Fields

  - `:message` — a human-readable description.
  - `:field` — the offending request field (e.g. `:column`, `:filters`,
    `:limit`), or `nil` for non-field errors.
  - `:reason` — a stable atom for programmatic matching. Common values:
    `:not_a_resource`, `:not_analyzable`, `:unknown_type`, `:not_allowed`,
    `:too_many`, `:too_large`, `:unknown_attribute`, `:bad_type`,
    `:invalid_value`, `:no_primary_read_action`, `:unsupported_data_layer`,
    `:internal_error`, `:not_supported`.

  ## Example

      case AshDyan.run(spec) do
        {:ok, result} -> result
        {:error, %AshDyan.Error{field: :limit, reason: :too_large}} ->
          # surface a friendly message to the caller
      end
  """

  defexception [:message, :field, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          field: atom() | nil,
          reason: atom() | nil
        }

  def exception(message) when is_binary(message), do: %__MODULE__{message: message}
  def exception(%__MODULE__{} = error), do: error

  # An already-raised `Ash.Error.*` (or any other exception struct) was passed
  # in. Preserve its message instead of treating it as a generic opts map and
  # collapsing to the generic "invalid AshDyan request".
  def exception(%{__exception__: true} = error),
    do: %__MODULE__{message: Exception.message(error)}

  def exception(opts) when is_map(opts) or is_list(opts) do
    get = fn key ->
      if is_map(opts), do: Map.get(opts, key), else: Keyword.get(opts, key)
    end

    field = get.(:field)
    reason = get.(:reason)
    message = get.(:message) || default_message(field, reason)
    %__MODULE__{message: message, field: field, reason: reason}
  end

  # Fallback for unrecognized error shapes (e.g. an `Ash.Error.*` raised by a
  # failed read). Preserve the original message instead of collapsing to the
  # generic "invalid AshDyan request".
  def exception(other), do: %__MODULE__{message: inspect(other)}

  defp default_message(nil, nil), do: "invalid AshDyan request"
  defp default_message(field, nil), do: "invalid AshDyan request: #{inspect(field)}"

  defp default_message(field, reason),
    do: "invalid AshDyan request: #{inspect(field)} (#{reason})"

  defimpl String.Chars do
    def to_string(%{message: message}), do: message
  end
end
