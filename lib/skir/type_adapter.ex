defmodule Skir.TypeAdapter do
  @moduledoc """
  Runtime serializer for one Skir type. Holds closures for every
  encode/decode operation.

  Every type - primitive, struct, enum, optional, array — exposes a
  `%TypeAdapter{}`. Composite TypeAdapters (struct/enum) build their
  closures at compile time with field types baked in.

  ## Fields

    * `is_default/1` — does this value equal the type's default?
      Used for trailing-default trimming in struct encoding.
    * `to_json/2` — encode to a JSON term (not bytes) given a flavor.
    * `decode_json/3` — decode from a parsed JSON term, given a path
      for error reporting. Returns the typed value or raises
      `Skir.DecodeError`.
    * `encode_binary/2` — append binary encoding to iodata accumulator.
    * `decode_binary/2` — decode from bitstring, return
      `{:ok, {value, rest}} | {:error, reason}`.
  """

  @enforce_keys [:is_default, :to_json, :decode_json, :encode_binary, :decode_binary]
  defstruct [:is_default, :to_json, :decode_json, :encode_binary, :decode_binary]

  @type t :: %__MODULE__{
          is_default: (term() -> boolean()),
          to_json: (term(), :dense | :readable -> term()),
          decode_json: (term(), [atom() | non_neg_integer()], :keep | :drop -> term()),
          encode_binary: (term(), iodata() -> iodata()),
          decode_binary: (bitstring(), :keep | :drop ->
                            {:ok, {term(), bitstring()}} | {:error, String.t()})
        }
end
