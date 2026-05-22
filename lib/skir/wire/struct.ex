defmodule Skir.Wire.Struct do
  @moduledoc """
  Wire-level struct encoding/decoding helpers.

  Struct wire format: `<slot_count_header> <slot_0_bytes> ... <slot_N-1_bytes>`

      Slot count 0:    <<0x00>> or <<0xF6>>
      Slot count 1-3:  <<0xF6 + count>>  (i.e. 0xF7, 0xF8, 0xF9)
      Slot count 4+:   <<0xFA, uint32(count)>>

  Trailing slots whose values are at their defaults are omitted; the
  slot_count itself is reduced.
  """

  alias Skir.Wire.Number

  @doc """
  Encode the struct header for `count` slots. Returns iodata.
  """
  @spec encode_slot_count(non_neg_integer()) :: iodata()
  def encode_slot_count(0), do: <<0x00>>
  def encode_slot_count(1), do: <<0xF7>>
  def encode_slot_count(2), do: <<0xF8>>
  def encode_slot_count(3), do: <<0xF9>>

  def encode_slot_count(n) when n > 3,
    do: [0xFA, Number.encode_uint32(n)]

  @doc """
  Decode the struct header. Returns `{:ok, {slot_count, rest}}`.
  Empty struct: `<<0>>` or `<<0xF6>>` → count = 0.
  """
  @spec decode_slot_count(binary()) :: {:ok, {non_neg_integer(), binary()}} | {:error, String.t()}
  def decode_slot_count(<<0x00, r::bits>>), do: {:ok, {0, r}}
  def decode_slot_count(<<0xF6, r::bits>>), do: {:ok, {0, r}}
  def decode_slot_count(<<0xF7, r::bits>>), do: {:ok, {1, r}}
  def decode_slot_count(<<0xF8, r::bits>>), do: {:ok, {2, r}}
  def decode_slot_count(<<0xF9, r::bits>>), do: {:ok, {3, r}}
  def decode_slot_count(<<0xFA, r::bits>>), do: Number.decode_uint32(r)

  def decode_slot_count(<<b, _::bits>>),
    do: {:error, "unexpected struct header: 0x#{Integer.to_string(b, 16)}"}

  def decode_slot_count(<<>>), do: {:error, "unexpected end of input"}
end
