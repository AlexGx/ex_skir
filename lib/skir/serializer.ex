defmodule Skir.Serializer do
  @moduledoc """
  User-facing wrapper around `Skir.TypeAdapter`. Provides encode/decode
  helpers that produce final binaries/strings and surface decode errors
  consistently.
  """

  alias Skir.TypeAdapter
  alias Skir.DecodeError

  @enforce_keys [:type_adapter, :module]
  defstruct [:type_adapter, :module, name: nil, qualified_name: nil, module_path: nil, doc: nil]

  @type t :: %__MODULE__{
          type_adapter: TypeAdapter.t(),
          module: module() | nil,
          name: String.t() | nil,
          qualified_name: String.t() | nil,
          module_path: String.t() | nil,
          doc: String.t() | nil
        }

  # ---- binary ----

  # The 4-byte "skir" prefix is a magic number on top-level binary payloads.
  # It does two things: marks payloads as Skir-binary (vs JSON or arbitrary
  # bytes), and lets `decode_binary` accept either format via prefix-check
  # dispatch. The prefix is added once at the boundary; nested struct/array
  # values within a payload don't get their own prefixes.
  @prefix "skir"

  @doc """
  Encode a value to binary using the given serializer. Returns a binary
  with a 4-byte `"skir"` prefix followed by the wire-format payload.
  """
  @spec encode_binary(t(), term()) :: binary()
  def encode_binary(%__MODULE__{type_adapter: ta}, value) do
    body = ta.encode_binary.(value, []) |> IO.iodata_to_binary()
    @prefix <> body
  end

  @doc """
  Decode bytes into a value. Returns `{:ok, value}` or
  `{:error, %DecodeError{}}`.

  Dispatches by prefix:
    * Bytes starting with `"skir"` are decoded as Skir binary.
    * Other bytes are tried as JSON.

  ## Options

    * `:keep` — when `true`, captures unrecognized trailing slots
      (structs) or unknown variant payloads (enums) for round-tripping.
      Default: `false`. Only use with trusted input.
  """
  @spec decode_binary(t(), binary(), keyword()) ::
          {:ok, term()} | {:error, DecodeError.t()}
  def decode_binary(%__MODULE__{} = s, bytes, opts \\ []) do
    {:ok, decode_binary!(s, bytes, opts)}
  rescue
    e in DecodeError -> {:error, e}
  end

  @doc """
  Decode bytes into a value. Raises `Skir.DecodeError` on failure.
  See `decode_binary/3` for prefix-dispatch behavior.
  """
  @spec decode_binary!(t(), binary(), keyword()) :: term()
  def decode_binary!(%__MODULE__{type_adapter: ta} = s, bytes, opts \\ []) do
    keep = if Keyword.get(opts, :keep, false), do: :keep, else: :drop

    case bytes do
      <<@prefix, body::binary>> ->
        decode_wire!(ta, body, keep)

      _ ->
        # No magic prefix - try JSON.
        try do
          decode_json!(s, bytes)
        rescue
          _ ->
            raise DecodeError,
              path: [],
              expected: :binary,
              got: bytes,
              reason: :malformed_input
        end
    end
  end

  defp decode_wire!(ta, body, keep) do
    case ta.decode_binary.(body, keep) do
      {:ok, {value, _rest}} ->
        value

      {:error, reason} ->
        raise DecodeError,
          path: [],
          expected: :binary,
          got: reason,
          reason: :malformed_input
    end
  end

  # ---- json ----

  def encode_json(%__MODULE__{type_adapter: ta}, value, flavor \\ :dense) do
    term = ta.to_json.(value, flavor)
    # @review: JSON.encode here?
    JSON.encode_to_iodata!(term) |> IO.iodata_to_binary()
  end

  def decode_json(%__MODULE__{} = s, json_bin) do
    {:ok, decode_json!(s, json_bin)}
  rescue
    e in DecodeError -> {:error, e}
  end

  def decode_json!(%__MODULE__{type_adapter: ta}, json_bin) when is_binary(json_bin) do
    term = JSON.decode!(json_bin)
    ta.decode_json.(term, [])
  end
end
