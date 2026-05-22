defmodule Skir.EncodeError do
  @moduledoc """
  Raised when a value cannot be encoded because its type does not match
  the schema. The message names the field path (with array indices),
  the expected Skir type (as declared in your schema), and the actual
  value with its Elixir type.

  ## Example

      iex> User.to_binary!(%User{name: 4, ...})
      ** (Skir.EncodeError) Skir could not encode `name`: expected :string, got 4 (integer)

  For nested structures the path includes field names and array indices:

      Skir could not encode `pets[0].name`: expected :string, got 4 (integer)
  """

  defexception [:path, :expected, :got]

  @type path_segment :: atom() | non_neg_integer()
  @type path :: [path_segment()]

  @type t :: %__MODULE__{
          path: path() | nil,
          expected: atom(),
          got: term()
        }

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{path: path, expected: expected, got: got}) do
    path_str = format_path(path)

    location =
      case path_str do
        "" -> ""
        p -> " `#{p}`"
      end

    "Skir could not encode#{location}: " <>
      "expected #{inspect(expected)}, got #{inspect(got)} (#{type_name(got)})"
  end

  # Formats a path list into a dotted/indexed string.
  #   [:name]                  -> "name"
  #   [:pets, 0, :name]        -> "pets[0].name"
  #   [:user, :pets, 2, :tag]  -> "user.pets[2].tag"
  defp format_path([]), do: ""

  defp format_path(path) do
    path
    |> Enum.reduce("", fn
      # Integer segment = array index, append [n] with no leading dot.
      i, acc when is_integer(i) ->
        acc <> "[#{i}]"

      # Atom segment = field name. Add a leading dot unless we're at the start.
      field, "" ->
        Atom.to_string(field)

      field, acc ->
        acc <> "." <> Atom.to_string(field)
    end)
  end

  defp type_name(v) when is_integer(v), do: "integer"
  defp type_name(v) when is_float(v), do: "float"
  defp type_name(v) when is_boolean(v), do: "boolean"
  defp type_name(v) when is_binary(v), do: "binary"
  defp type_name(v) when is_atom(v), do: "atom"
  defp type_name(v) when is_list(v), do: "list"
  defp type_name(v) when is_map(v), do: "map"
  defp type_name(v) when is_tuple(v), do: "tuple"
  defp type_name(_), do: "unknown"
end
