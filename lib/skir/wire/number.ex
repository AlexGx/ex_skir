# @review: rename to Int ?
defmodule Skir.Wire.Number do
  @moduledoc """
  Encode/decode integers with Skir's marker-byte scheme.

  Marker bytes for int family:

      0x00..0xe7  single byte, value 0..231
      0xe8        + uint16 LE  (232..65535)
      0xe9        + uint32 LE  (65536..2^32-1)
      0xea        + uint64 LE  (hash64 > 2^32-1)
      0xeb        + uint8      (negative: subtract 256)
      0xec        + uint16 LE  (negative: subtract 65536)
      0xed        + int32  LE  (negative below -65536)
      0xee        + int64  LE  (signed beyond int32 range)
  """

  @doc "Encode a signed int32 value."
  def encode_int32(n) when is_integer(n) and n >= 0 and n <= 231, do: <<n>>
  def encode_int32(n) when is_integer(n) and n >= 232 and n <= 0xFFFF, do: <<0xE8, n::16-little>>

  def encode_int32(n) when is_integer(n) and n >= 0x10000 and n <= 0x7FFFFFFF,
    do: <<0xE9, n::32-little>>

  def encode_int32(n) when is_integer(n) and n >= -256 and n <= -1,
    do: <<0xEB, n + 256>>

  def encode_int32(n) when is_integer(n) and n >= -0x10000 and n <= -257,
    do: <<0xEC, n + 0x10000::16-little>>

  def encode_int32(n) when is_integer(n) and n >= -0x80000000 and n <= -0x10001,
    do: <<0xED, n::32-signed-little>>

  def encode_int32(other), do: raise(Skir.EncodeError, path: [], expected: :int32, got: other)

  @doc "Encode a signed int64. Uses shortest encoding."
  def encode_int64(n) when is_integer(n) and n >= -0x80000000 and n <= 0x7FFFFFFF,
    do: encode_int32(n)

  def encode_int64(n) when is_integer(n) and n >= -0x8000000000000000 and n <= 0x7FFFFFFFFFFFFFFF,
    do: <<0xEE, n::64-signed-little>>

  def encode_int64(other), do: raise(Skir.EncodeError, path: [], expected: :int64, got: other)

  @doc "Encode an unsigned uint64 (used for hash64)."
  def encode_hash64(n) when is_integer(n) and n >= 0 and n <= 231, do: <<n>>
  def encode_hash64(n) when is_integer(n) and n > 231 and n <= 0xFFFF, do: <<0xE8, n::16-little>>

  def encode_hash64(n) when is_integer(n) and n > 0xFFFF and n <= 0xFFFFFFFF,
    do: <<0xE9, n::32-little>>

  def encode_hash64(n) when is_integer(n) and n > 0xFFFFFFFF and n <= 0xFFFFFFFFFFFFFFFF,
    do: <<0xEA, n::64-little>>

  def encode_hash64(other), do: raise(Skir.EncodeError, path: [], expected: :hash64, got: other)

  @doc "Encode a small unsigned integer (slot counts, variant numbers, lengths)."
  def encode_uint32(n) when is_integer(n) and n >= 0 and n <= 231, do: <<n>>
  def encode_uint32(n) when is_integer(n) and n > 231 and n <= 0xFFFF, do: <<0xE8, n::16-little>>

  def encode_uint32(n) when is_integer(n) and n > 0xFFFF and n <= 0xFFFFFFFF,
    do: <<0xE9, n::32-little>>

  # uint32 is an internal (slot counts, length prefixes, variant nums),
  # not a user-facing schema type. A bad value here indicates a lib bug, not user error.
  def encode_uint32(other),
    do:
      raise(
        ArgumentError,
        "Skir internal error: encode_uint32 expects 0..#{0xFFFFFFFF}, got #{inspect(other)}"
      )

  @spec decode_int32(binary()) :: {:ok, {integer(), binary()}} | {:error, String.t()}
  def decode_int32(<<n, r::bits>>) when n <= 231, do: {:ok, {n, r}}
  def decode_int32(<<0xE8, n::16-little, r::bits>>), do: {:ok, {n, r}}

  def decode_int32(<<0xE9, n::32-little, r::bits>>) do
    if n <= 0x7FFFFFFF, do: {:ok, {n, r}}, else: {:error, "int32 overflow: #{n}"}
  end

  def decode_int32(<<0xEB, n, r::bits>>), do: {:ok, {n - 256, r}}
  def decode_int32(<<0xEC, n::16-little, r::bits>>), do: {:ok, {n - 0x10000, r}}
  def decode_int32(<<0xED, n::32-signed-little, r::bits>>), do: {:ok, {n, r}}

  def decode_int32(<<0xF0, v::32-float-little, r::bits>>), do: {:ok, {trunc(v), r}}
  def decode_int32(<<0xF1, v::64-float-little, r::bits>>), do: {:ok, {trunc(v), r}}

  def decode_int32(<<0xEE, _::64, _::bits>>),
    do: {:error, "int64 value cannot be decoded as int32"}

  def decode_int32(<<0xEA, _::64, _::bits>>),
    do: {:error, "hash64 value cannot be decoded as int32"}

  def decode_int32(<<b, _::bits>>),
    do: {:error, "unexpected marker for int32: 0x#{Integer.to_string(b, 16)}"}

  def decode_int32(<<>>), do: {:error, "unexpected end of input"}

  @spec decode_int64(binary()) :: {:ok, {integer(), binary()}} | {:error, String.t()}
  def decode_int64(<<n, r::bits>>) when n <= 231, do: {:ok, {n, r}}
  def decode_int64(<<0xE8, n::16-little, r::bits>>), do: {:ok, {n, r}}
  def decode_int64(<<0xE9, n::32-little, r::bits>>), do: {:ok, {n, r}}
  def decode_int64(<<0xEB, n, r::bits>>), do: {:ok, {n - 256, r}}
  def decode_int64(<<0xEC, n::16-little, r::bits>>), do: {:ok, {n - 0x10000, r}}
  def decode_int64(<<0xED, n::32-signed-little, r::bits>>), do: {:ok, {n, r}}
  def decode_int64(<<0xEE, n::64-signed-little, r::bits>>), do: {:ok, {n, r}}

  def decode_int64(<<0xEA, n::64-little, r::bits>>) do
    if n <= 0x7FFFFFFFFFFFFFFF, do: {:ok, {n, r}}, else: {:error, "hash64 > int64"}
  end

  # Forward-compat: float wire truncated to integer.
  def decode_int64(<<0xF0, v::32-float-little, r::bits>>), do: {:ok, {trunc(v), r}}
  def decode_int64(<<0xF1, v::64-float-little, r::bits>>), do: {:ok, {trunc(v), r}}

  def decode_int64(<<b, _::bits>>),
    do: {:error, "unexpected marker for int64: 0x#{Integer.to_string(b, 16)}"}

  def decode_int64(<<>>), do: {:error, "unexpected end of input"}

  @spec decode_hash64(binary()) :: {:ok, {non_neg_integer(), binary()}} | {:error, String.t()}
  def decode_hash64(<<n, r::bits>>) when n <= 231, do: {:ok, {n, r}}
  def decode_hash64(<<0xE8, n::16-little, r::bits>>), do: {:ok, {n, r}}
  def decode_hash64(<<0xE9, n::32-little, r::bits>>), do: {:ok, {n, r}}
  def decode_hash64(<<0xEA, n::64-little, r::bits>>), do: {:ok, {n, r}}

  def decode_hash64(<<m, _::bits>>) when m in [0xEB, 0xEC, 0xED, 0xEE],
    do: {:error, "negative or signed value cannot be decoded as hash64"}

  def decode_hash64(<<b, _::bits>>),
    do: {:error, "unexpected marker for hash64: 0x#{Integer.to_string(b, 16)}"}

  def decode_hash64(<<>>), do: {:error, "unexpected end of input"}

  @spec decode_uint32(binary()) :: {:ok, {non_neg_integer(), binary()}} | {:error, String.t()}
  def decode_uint32(<<n, r::binary>>) when n <= 231, do: {:ok, {n, r}}
  def decode_uint32(<<0xE8, n::16-little, r::binary>>), do: {:ok, {n, r}}
  def decode_uint32(<<0xE9, n::32-little, r::binary>>), do: {:ok, {n, r}}

  def decode_uint32(<<b, _::binary>>),
    do: {:error, "unexpected marker for uint32: 0x#{Integer.to_string(b, 16)}"}

  def decode_uint32(<<>>), do: {:error, "unexpected end of input"}
end
