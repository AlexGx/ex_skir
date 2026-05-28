defmodule Skir do
  @moduledoc """
  Skir — protobuf-like serialization with strong schema-evolution guarantees.

  ## Modules

    * `Skir.Struct` - DSL for defining a struct type
    * `Skir.Enum` - DSL for defining a sum type
    * `Skir.Constants` - schema-defined constants
    * `Skir.Serializer` - runtime encode/decode API
    * `Skir.TypeAdapter` - the central encode/decode record (per type)
  """

  @doc "Polymorphic encode to binary. Dispatches on `__struct__`."
  def encode_binary(%mod{} = value), do: mod.to_binary(value)

  @doc "Polymorphic encode to JSON."
  def encode_json(%mod{} = value, flavor \\ :dense), do: mod.to_json(value, flavor)
end
