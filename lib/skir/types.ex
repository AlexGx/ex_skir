defmodule Skir.Types do
  @moduledoc """
  Named typespecs for Skir primitives.

  These types appear in the auto-generated `@type t` of every `use Skir.Struct`
  and `use Skir.Enum` module. Use them in your own typespecs when accepting
  Skir-typed values:

      @spec process(Skir.Types.int32()) :: :ok
  """

  @typedoc "Signed 32-bit int."
  @type int32 :: -2_147_483_648..2_147_483_647

  @typedoc "Signed 64-bit int."
  @type int64 :: -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  @typedoc "Unsigned 64-bit int."
  @type hash64 :: 0..18_446_744_073_709_551_615

  @typedoc "Single-precision floating point."
  @type float32 :: float()

  @typedoc "Double-precision floating point."
  @type float64 :: float()

  @typedoc "Opaque binary data (matches the Skir `:bytes` field type)."
  @type bytes :: binary()

  @typedoc "UTC `DateTime` with millisecond precision."
  @type timestamp :: DateTime.t()
end
