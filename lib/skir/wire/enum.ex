defmodule Skir.Wire.Enum do
  @moduledoc """
  Wire-level enum encoding/decoding helpers.

  Enum wire format:

      Constant variants:   encode the variant number as a uint32.
      Wrapper variants:
        - Number 1..4:     single byte 0xFB..0xFE, then payload.
        - Number >= 5:     0xF8 (sic — overloaded but distinguishable
                                  by context), uint32 number, then payload.

  ## Marker overloading note

  `0xF8` is overloaded: in struct context it means "slot count = 2", in
  enum context it means "wrapper variant number follows". This is fine
  because the parent type tells the decoder which context it's in.
  """

  alias Skir.Wire.Number

  # Encode the header bytes for a wrapper variant of given number.
  @spec encode_wrapper_header(pos_integer()) :: iodata()
  def encode_wrapper_header(n) when n in 1..4, do: <<0xFA + n>>

  def encode_wrapper_header(n) when n >= 5,
    do: [0xF8, Number.encode_uint32(n)]
end
