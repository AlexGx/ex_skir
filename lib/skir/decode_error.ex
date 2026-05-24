defmodule Skir.DecodeError do
  @moduledoc """
  Raised when decoding fails for a reason that is *not* covered by Skir's
  forward-compatibility rules.

  Schema drift - unknown fields, unknown variants, removed fields, missing
  trailing fields, zeros in non-numeric slots - does NOT raise; the decoder
  silently falls back to defaults or `:unknown`.

  ## Path

  `path` is built bottom-up as the decoder unwinds. Generated decoders
  prepend the field name or array index on rescue, so the happy path pays
  nothing.
  """
  defexception [:path, :expected, :got, :reason]

  @type path_segment :: atom() | non_neg_integer()
  @type path :: [path_segment()]

  @type reason ::
          :type_mismatch
          | :unknown_enum_variant
          | :malformed_input
          | :invalid_utf8
          | :out_of_range

  @type t :: %__MODULE__{
          path: path() | nil,
          expected: term(),
          got: term(),
          reason: reason()
        }

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = e) do
    path = format_path(e.path || [])

    base =
      case e.reason do
        :type_mismatch ->
          "type mismatch: expected #{inspect(e.expected)}, got #{inspect(e.got)}"

        :unknown_enum_variant ->
          "unknown enum variant #{inspect(e.got)}"

        :malformed_input ->
          "malformed input: #{inspect(e.got)}"

        :invalid_utf8 ->
          "invalid UTF-8 in string"

        :out_of_range ->
          "value out of range for #{inspect(e.expected)}: #{inspect(e.got)}"
      end

    "#{base} at #{path}"
  end

  @doc "Prepend a path segment to an in-flight error."
  @spec prepend(t(), path_segment()) :: t()
  def prepend(%__MODULE__{path: path} = e, segment),
    do: %{e | path: [segment | path || []]}

  defp format_path([]), do: "<root>"

  defp format_path(parts) do
    parts
    |> Enum.map_join("", fn
      i when is_integer(i) -> "[#{i}]"
      a when is_atom(a) -> "." <> Atom.to_string(a)
    end)
    |> String.trim_leading(".")
  end
end
