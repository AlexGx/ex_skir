# deprecated
defmodule Skir.Struct.Behaviour do
  @moduledoc """
  Functions auto-generated for every `use Skir.Struct` module.

  Implemented by the `Skir.Struct` macro; you don't need to declare
  `@behaviour Skir.Struct.Behaviour` manually.
  """

  # @review
  @doc "Construct a struct from a complete map of fields."
  @callback new(map()) :: struct()

  @doc "Construct a struct from partial fields; missing fields use defaults."
  @callback partial(map()) :: struct()

  @doc "Return a struct with all default values."
  @callback default() :: struct()

  @doc "Merge a map of overrides into an existing struct."
  @callback merge(struct(), map()) :: struct()

  @doc "Encode the value to Skir-binary (with `\"skir\"` magic prefix)."
  @callback to_binary(struct()) :: binary()

  @doc "Encode the value to JSON (dense or readable form)."
  @callback to_json(struct()) :: binary()
  @callback to_json(struct(), :dense | :readable) :: binary()

  @doc "Decode bytes into a struct. Bytes may be Skir-binary or JSON."
  @callback from_binary(binary()) :: {:ok, struct()} | {:error, Skir.DecodeError.t()}
  @callback from_binary(binary(), keyword()) :: {:ok, struct()} | {:error, Skir.DecodeError.t()}

  @doc "Decode bytes, raising `Skir.DecodeError` on failure."
  @callback from_binary!(binary()) :: struct()
  @callback from_binary!(binary(), keyword()) :: struct()

  @doc "Decode a JSON string into a struct."
  @callback from_json(binary()) :: {:ok, struct()} | {:error, Skir.DecodeError.t()}
  @callback from_json!(binary()) :: struct()

  @doc "Reflection: returns the schema metadata."
  @callback __skir_schema__() :: map()

  @doc "Reflection: returns the runtime serializer for this struct."
  @callback __skir_serializer__() :: Skir.Serializer.t()
end
