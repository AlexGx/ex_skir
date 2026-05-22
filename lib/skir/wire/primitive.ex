defmodule Skir.Wire.Primitive do
  @moduledoc """
  Non-int primitives: bool, float32, float64, timestamp, string, bytes, null.

  Marker bytes:

      0x00    universal zero/default
      0x01    true (bool only)
      0xef    timestamp (+ 8 bytes int64 millis)
      0xf0    float32 (+ 4 bytes IEEE754 LE)
      0xf1    float64 (+ 8 bytes IEEE754 LE)
      0xf2    empty string
      0xf3    non-empty string (+ uint32 len, + bytes)
      0xf4    empty bytes
      0xf5    non-empty bytes (+ uint32 len, + bytes)
      0xff    null

  Per the spec, `<<0>>` is a valid input for any type and decodes as that
  type's default value.
  """

  alias Skir.Wire.Number

  @epoch ~U[1970-01-01 00:00:00.000Z]

  # Bool

  @spec encode_bool(boolean()) :: iodata()
  def encode_bool(true), do: <<0x01>>
  def encode_bool(false), do: <<0x00>>
  def encode_bool(other), do: raise(Skir.EncodeError, path: [], expected: :bool, got: other)

  @spec decode_bool(binary()) ::
          {:ok, {boolean(), binary()}} | {:error, String.t()}
  def decode_bool(<<0x00, r::bits>>), do: {:ok, {false, r}}
  def decode_bool(<<0x01, r::bits>>), do: {:ok, {true, r}}

  def decode_bool(<<b, _::bits>>),
    do: {:error, "unexpected byte for bool: 0x#{Integer.to_string(b, 16)}"}

  def decode_bool(<<>>), do: {:error, "unexpected end of input"}

  # Floats

  @spec encode_float32(0 | float() | :nan | :infinity | :neg_infinity) :: binary()
  def encode_float32(0), do: <<0x00>>
  def encode_float32(+0.0), do: <<0x00>>
  def encode_float32(-0.0), do: <<0x00>>
  def encode_float32(:nan), do: <<0xF0, 0, 0, 0xC0, 0x7F>>
  def encode_float32(:infinity), do: <<0xF0, 0, 0, 0x80, 0x7F>>
  def encode_float32(:neg_infinity), do: <<0xF0, 0, 0, 0x80, 0xFF>>
  def encode_float32(f) when is_float(f), do: <<0xF0, f::32-float-little>>
  def encode_float32(other), do: raise(Skir.EncodeError, path: [], expected: :float32, got: other)

  @spec decode_float32(binary()) ::
          {:ok, {float() | :nan | :infinity | :neg_infinity, binary()}}
          | {:error, String.t()}
  def decode_float32(<<0x00, r::bits>>), do: {:ok, {0.0, r}}
  def decode_float32(<<0xF0, 0, 0, 0x80, 0x7F, r::bits>>), do: {:ok, {:infinity, r}}
  def decode_float32(<<0xF0, 0, 0, 0x80, 0xFF, r::bits>>), do: {:ok, {:neg_infinity, r}}

  def decode_float32(<<0xF0, a::16-little, 1::1, b::7, _::1, 0b1111111::7, r::bits>>)
      when a != 0 or b != 0,
      do: {:ok, {:nan, r}}

  def decode_float32(<<0xF0, f::32-float-little, r::bits>>), do: {:ok, {f, r}}

  def decode_float32(<<b, _::bits>>),
    do: {:error, "unexpected byte for float32: 0x#{Integer.to_string(b, 16)}"}

  def decode_float32(<<>>), do: {:error, "unexpected end of input"}

  @spec encode_float64(0 | float() | :nan | :infinity | :neg_infinity) :: binary()
  def encode_float64(0), do: <<0x00>>
  def encode_float64(+0.0), do: <<0x00>>
  def encode_float64(-0.0), do: <<0x00>>
  def encode_float64(:nan), do: <<0xF1, 1, 0, 0, 0, 0, 0, 0xF8, 0x7F>>
  def encode_float64(:infinity), do: <<0xF1, 0, 0, 0, 0, 0, 0, 0xF0, 0x7F>>
  def encode_float64(:neg_infinity), do: <<0xF1, 0, 0, 0, 0, 0, 0, 0xF0, 0xFF>>
  def encode_float64(f) when is_float(f), do: <<0xF1, f::64-float-little>>

  def encode_float64(other),
    do: raise(Skir.EncodeError, path: [], expected: :float64, got: other)

  @spec decode_float64(bitstring()) ::
          {:ok, {float() | :nan | :infinity | :neg_infinity, bitstring()}}
          | {:error, String.t()}
  def decode_float64(<<0x00, r::bits>>), do: {:ok, {0.0, r}}

  def decode_float64(<<0xF1, 0::48, 0b1111::4, 0::4, 0x7F, r::bits>>),
    do: {:ok, {:infinity, r}}

  def decode_float64(<<0xF1, 0::48, 0b1111::4, 0::4, 0xFF, r::bits>>),
    do: {:ok, {:neg_infinity, r}}

  def decode_float64(<<0xF1, a::48, 0b1111::4, b::4, _::1, 0b1111111::7, r::bits>>)
      when a != 0 or b != 0,
      do: {:ok, {:nan, r}}

  def decode_float64(<<0xF1, f::64-float-little, r::bits>>), do: {:ok, {f, r}}

  def decode_float64(<<b, _::bits>>),
    do: {:error, "unexpected byte for float64: 0x#{Integer.to_string(b, 16)}"}

  def decode_float64(<<>>), do: {:error, "unexpected end of input"}

  # Timestamp

  @spec encode_timestamp(DateTime.t() | integer()) :: binary()
  def encode_timestamp(%DateTime{} = dt), do: encode_timestamp(DateTime.to_unix(dt, :millisecond))

  def encode_timestamp(0), do: <<0x00>>

  def encode_timestamp(ms)
      when is_integer(ms) and ms >= -0x8000_0000_0000_0000 and ms <= 0x7FFF_FFFF_FFFF_FFFF,
      do: <<0xEF, ms::64-signed-little>>

  def encode_timestamp(other),
    do: raise(Skir.EncodeError, path: [], expected: :timestamp, got: other)

  @spec decode_timestamp(binary()) ::
          {:ok, {DateTime.t(), binary()}} | {:error, String.t()}
  def decode_timestamp(<<0x00, r::bits>>), do: {:ok, {@epoch, r}}

  def decode_timestamp(<<0xEF, ms::64-signed-little, r::bits>>) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> {:ok, {dt, r}}
      _ -> {:error, "timestamp out of range: #{ms}"}
    end
  end

  def decode_timestamp(<<b, _::bits>>),
    do: {:error, "unexpected byte for timestamp: 0x#{Integer.to_string(b, 16)}"}

  def decode_timestamp(<<>>), do: {:error, "unexpected end of input"}

  # String

  @spec encode_string(binary()) :: iodata()
  def encode_string(""), do: <<0xF2>>

  def encode_string(s) when is_binary(s), do: [0xF3, Number.encode_uint32(byte_size(s)), s]

  def encode_string(other), do: raise(Skir.EncodeError, path: [], expected: :string, got: other)

  @spec decode_string(binary()) :: {:ok, {String.t(), binary()}} | {:error, String.t()}
  def decode_string(<<0x00, r::bits>>), do: {:ok, {"", r}}
  def decode_string(<<0xF2, r::bits>>), do: {:ok, {"", r}}

  def decode_string(<<0xF3, r::bits>>) do
    with {:ok, {len, r2}} <- Number.decode_uint32(r),
         <<s::binary-size(len), r3::bits>> <- r2 do
      if String.valid?(s),
        do: {:ok, {s, r3}},
        else: {:error, "invalid UTF-8 in string"}
    else
      {:error, _} = err -> err
      _ -> {:error, "string length exceeds available input"}
    end
  end

  def decode_string(<<b, _::bits>>),
    do: {:error, "unexpected byte for string: 0x#{Integer.to_string(b, 16)}"}

  def decode_string(<<>>), do: {:error, "unexpected end of input"}

  # Bytes

  @spec encode_bytes(binary()) :: iodata()
  def encode_bytes(""), do: <<0xF4>>

  def encode_bytes(b) when is_binary(b),
    do: [0xF5, Number.encode_uint32(byte_size(b)), b]

  def encode_bytes(other), do: raise(Skir.EncodeError, path: [], expected: :bytes, got: other)

  @spec decode_bytes(binary()) ::
          {:ok, {binary(), binary()}} | {:error, String.t()}
  def decode_bytes(<<0x00, r::bits>>), do: {:ok, {"", r}}
  def decode_bytes(<<0xF4, r::bits>>), do: {:ok, {"", r}}

  def decode_bytes(<<0xF5, r::bits>>) do
    with {:ok, {len, r2}} <- Number.decode_uint32(r),
         <<b::binary-size(len), r3::bits>> <- r2 do
      {:ok, {b, r3}}
    else
      {:error, _} = err -> err
      _ -> {:error, "bytes length exceeds available input"}
    end
  end

  def decode_bytes(<<b, _::bits>>),
    do: {:error, "unexpected byte for bytes: 0x#{Integer.to_string(b, 16)}"}

  def decode_bytes(<<>>), do: {:error, "unexpected end of input"}

  # Null

  @spec encode_null() :: binary()
  def encode_null, do: <<0xFF>>
end
