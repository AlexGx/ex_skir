defmodule Skir.Wire.Skip do
  @moduledoc """
  Skip past one Skir-encoded value, used for forward-compatibility when
  the decoder encounters unrecognized fields/variants.
  """

  alias Skir.Wire.Number

  @spec skip_value(binary()) :: {:ok, binary()} | {:error, String.t()}

  # 0x00..0xe7 (single byte)
  def skip_value(<<n, r::bits>>) when n <= 0xE7, do: {:ok, r}

  # integers
  def skip_value(<<0xE8, _::16, r::bits>>), do: {:ok, r}
  def skip_value(<<0xE9, _::32, r::bits>>), do: {:ok, r}
  def skip_value(<<0xEA, _::64, r::bits>>), do: {:ok, r}
  def skip_value(<<0xEB, _::8, r::bits>>), do: {:ok, r}
  def skip_value(<<0xEC, _::16, r::bits>>), do: {:ok, r}
  def skip_value(<<0xED, _::32, r::bits>>), do: {:ok, r}
  def skip_value(<<0xEE, _::64, r::bits>>), do: {:ok, r}

  # timestamp
  def skip_value(<<0xEF, _::64, r::bits>>), do: {:ok, r}

  # floats
  def skip_value(<<0xF0, _::32, r::bits>>), do: {:ok, r}
  def skip_value(<<0xF1, _::64, r::bits>>), do: {:ok, r}

  # empty string/bytes
  def skip_value(<<0xF2, r::bits>>), do: {:ok, r}
  def skip_value(<<0xF4, r::bits>>), do: {:ok, r}

  # length-prefixed string/bytes
  def skip_value(<<0xF3, r::bits>>), do: skip_lp(r)
  def skip_value(<<0xF5, r::bits>>), do: skip_lp(r)

  # empty struct/array
  def skip_value(<<0xF6, r::bits>>), do: {:ok, r}

  # length 1/2/3 arrays
  def skip_value(<<0xF7, r::bits>>), do: skip_n_values(1, r)
  def skip_value(<<0xF8, r::bits>>), do: skip_n_values(2, r)
  def skip_value(<<0xF9, r::bits>>), do: skip_n_values(3, r)

  # long array/struct
  def skip_value(<<0xFA, r::bits>>) do
    with {:ok, {len, r2}} <- Number.decode_uint32(r) do
      skip_n_values(len, r2)
    end
  end

  # wrapper variants 1..4: skip 1 payload
  def skip_value(<<m, r::bits>>) when m in 0xFB..0xFE,
    do: skip_n_values(1, r)

  # null
  def skip_value(<<0xFF, r::bits>>), do: {:ok, r}

  def skip_value(<<>>), do: {:error, "unexpected end of input"}

  def skip_value(<<b, _::bits>>),
    do: {:error, "unknown marker: 0x#{Integer.to_string(b, 16)}"}

  @spec skip_n_values(non_neg_integer(), bitstring()) ::
          {:ok, bitstring()} | {:error, String.t()}
  def skip_n_values(0, bits), do: {:ok, bits}

  def skip_n_values(n, bits) when n > 0 do
    case skip_value(bits) do
      {:ok, rest} -> skip_n_values(n - 1, rest)
      {:error, _} = err -> err
    end
  end

  defp skip_lp(bits) do
    with {:ok, {len, r}} <- Number.decode_uint32(bits),
         <<_::binary-size(len), r2::bits>> <- r do
      {:ok, r2}
    else
      {:error, _} = err -> err
      _ -> {:error, "length-prefixed value extends beyond input"}
    end
  end

  @doc "Capture the bytes of one value without removing them from input."
  @spec capture_value(binary()) ::
          {:ok, {binary(), binary()}} | {:error, String.t()}
  def capture_value(bits) do
    before_bits = bit_size(bits)

    case skip_value(bits) do
      {:ok, rest} ->
        consumed = div(before_bits - bit_size(rest), 8)
        <<captured::binary-size(consumed), _::bits>> = bits
        {:ok, {captured, rest}}

      {:error, _} = err ->
        err
    end
  end

  @spec capture_value(binary()) ::
          {:ok, {binary(), binary()}} | {:error, String.t()}
  def capture_n_values(n, bits) when n >= 0 do
    before_bits = bit_size(bits)

    case skip_n_values(n, bits) do
      {:ok, rest} ->
        consumed = div(before_bits - bit_size(rest), 8)
        <<captured::binary-size(consumed), _::bits>> = bits
        {:ok, {captured, rest}}

      {:error, _} = err ->
        err
    end
  end
end
