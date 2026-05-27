defmodule Skir.Serializer.Builtin do
  @moduledoc """
  Pre-built `Skir.TypeAdapter` values for primitive types and composites.

  Each function returns a `%TypeAdapter{}`. Generated struct/enum code
  references these for their field types.
  """

  alias Skir.TypeAdapter
  alias Skir.Wire.Number
  alias Skir.Wire.Primitive
  alias Skir.TypeDescriptor

  # Adapt a 1-arg Wire decoder into a 2-arg TypeAdapter decoder.
  # Primitives can't preserve unrecognized data, so the keep flag is ignored.
  defp lift(decoder), do: fn bits, _keep -> decoder.(bits) end

  # ---- bool ----

  def bool do
    %TypeAdapter{
      is_default: &(&1 == false),
      to_json: fn
        v, :dense -> if v, do: 1, else: 0
        v, :readable -> v
      end,
      decode_json: fn
        true, _, _ -> true
        false, _, _ -> false
        nil, _, _ -> false
        n, _, _ when is_integer(n) -> n != 0
        f, _, _ when is_float(f) -> f != 0.0
        "0", _, _ -> false
        s, _, _ when is_binary(s) -> true
        _other, _, _ -> false
      end,
      encode_binary: fn v, acc -> [acc, Primitive.encode_bool(v)] end,
      decode_binary: lift(&Primitive.decode_bool/1),
      type_descriptor: fn -> primitive_td(:bool) end
    }
  end

  # ---- int32 / int64 / hash64 ----

  def int32 do
    %TypeAdapter{
      is_default: &(&1 == 0),
      to_json: fn v, _ -> v end,
      decode_json: fn
        n, _, _ when is_integer(n) -> n
        f, _, _ when is_float(f) -> trunc(f)
        nil, _, _ -> 0
        s, _, _ when is_binary(s) -> parse_int_lenient(s)
        _other, _, _ -> 0
      end,
      encode_binary: fn v, acc -> [acc, Number.encode_int32(v)] end,
      decode_binary: lift(&Number.decode_int32/1),
      type_descriptor: fn -> primitive_td(:int32) end
    }
  end

  def int64 do
    %TypeAdapter{
      is_default: &(&1 == 0),
      to_json: fn
        v, _ when is_integer(v) and v in -9_007_199_254_740_991..9_007_199_254_740_991 -> v
        v, _ when is_integer(v) -> Integer.to_string(v)
      end,
      decode_json: fn
        n, _, _ when is_integer(n) -> n
        f, _, _ when is_float(f) -> round(f)
        nil, _, _ -> 0
        s, _, _ when is_binary(s) -> parse_int_lenient(s)
        _other, _, _ -> 0
      end,
      encode_binary: fn v, acc -> [acc, Number.encode_int64(v)] end,
      decode_binary: lift(&Number.decode_int64/1),
      type_descriptor: fn -> primitive_td(:int64) end
    }
  end

  def hash64 do
    %TypeAdapter{
      is_default: &(&1 == 0),
      to_json: fn
        v, _ when is_integer(v) and v <= 9_007_199_254_740_991 -> v
        v, _ when is_integer(v) -> Integer.to_string(v)
      end,
      decode_json: fn
        n, _, _ when is_integer(n) and n >= 0 -> n
        # negative → default
        n, _, _ when is_integer(n) -> 0
        f, _, _ when is_float(f) and f >= 0.0 -> round(f)
        # negative float → default
        f, _, _ when is_float(f) -> 0
        nil, _, _ -> 0
        s, _, _ when is_binary(s) -> parse_int_lenient(s)
        _other, _, _ -> 0
      end,
      encode_binary: fn v, acc -> [acc, Number.encode_hash64(v)] end,
      decode_binary: lift(&Number.decode_hash64/1),
      type_descriptor: fn -> primitive_td(:hash64) end
    }
  end

  # ---- float32 / float64 ----

  def float32,
    do: float_adapter(:float32, &Primitive.encode_float32/1, &Primitive.decode_float32/1)

  def float64,
    do: float_adapter(:float64, &Primitive.encode_float64/1, &Primitive.decode_float64/1)

  defp float_adapter(name, enc, dec) do
    %TypeAdapter{
      is_default: &float_default?/1,
      to_json: fn
        :nan, _ -> "NaN"
        :infinity, _ -> "Infinity"
        :neg_infinity, _ -> "-Infinity"
        v, _ -> float_to_json_value(v)
      end,
      decode_json: fn
        f, _, _ when is_float(f) -> f
        n, _, _ when is_integer(n) -> n * 1.0
        nil, _, _ -> 0.0
        "NaN", _, _ -> :nan
        "Infinity", _, _ -> :infinity
        "-Infinity", _, _ -> :neg_infinity
        s, _, _ when is_binary(s) -> parse_float_lenient(s)
        _other, _, _ -> 0.0
      end,
      encode_binary: fn v, acc -> [acc, enc.(v)] end,
      decode_binary: lift(dec),
      type_descriptor: fn -> primitive_td(name) end
    }
  end

  # experimental
  defp float_to_json_value(v) when is_float(v) do
    truncated = trunc(v)

    if truncated == v do
      truncated
    end || v
  end

  defp float_default?(0), do: true
  defp float_default?(+0.0), do: true
  defp float_default?(-0.0), do: true
  defp float_default?(_), do: false

  # ---- string ----

  def string do
    %TypeAdapter{
      is_default: &(&1 == ""),
      to_json: fn v, _ -> v end,
      decode_json: fn
        s, _, _ when is_binary(s) -> s
        nil, _, _ -> ""
        n, _, _ when is_integer(n) -> ""
        f, _, _ when is_float(f) -> ""
        _other, _, _ -> ""
      end,
      encode_binary: fn v, acc -> [acc, Primitive.encode_string(v)] end,
      decode_binary: lift(&Primitive.decode_string/1),
      type_descriptor: fn -> primitive_td(:string) end
    }
  end

  # ---- bytes ----

  def bytes do
    %TypeAdapter{
      is_default: &(&1 == ""),
      to_json: fn
        v, :dense -> Base.encode64(v)
        v, :readable -> "hex:" <> Base.encode16(v, case: :lower)
      end,
      decode_json: fn
        "hex:" <> hex, _, _ ->
          case Base.decode16(hex, case: :mixed) do
            {:ok, b} -> b
            :error -> ""
          end

        s, _, _ when is_binary(s) ->
          case Base.decode64(s) do
            {:ok, b} -> b
            :error -> ""
          end

        nil, _, _ ->
          ""

        n, _, _ when is_integer(n) ->
          ""

        f, _, _ when is_float(f) ->
          ""

        _other, _, _ ->
          ""
      end,
      encode_binary: fn v, acc -> [acc, Primitive.encode_bytes(v)] end,
      decode_binary: lift(&Primitive.decode_bytes/1),
      type_descriptor: fn -> primitive_td(:bytes) end
    }
  end

  # ---- timestamp ----

  @epoch ~U[1970-01-01 00:00:00.000Z]

  def timestamp do
    %TypeAdapter{
      is_default: &(&1 == @epoch),
      to_json: fn
        %DateTime{} = dt, :dense ->
          DateTime.to_unix(dt, :millisecond)

        %DateTime{} = dt, :readable ->
          Jason.OrderedObject.new([
            {"unix_millis", DateTime.to_unix(dt, :millisecond)},
            {"formatted", DateTime.to_iso8601(dt)}
          ])
      end,
      decode_json: fn
        ms, _, _ when is_integer(ms) -> from_unix_ms_safe(ms)
        f, _, _ when is_float(f) -> from_unix_ms_safe(round(f))
        %{"unix_millis" => ms}, _, _ when is_integer(ms) -> from_unix_ms_safe(ms)
        nil, _, _ -> @epoch
        s, _, _ when is_binary(s) -> from_unix_ms_safe(parse_int_lenient(s))
        _other, _, _ -> @epoch
      end,
      encode_binary: fn v, acc -> [acc, Primitive.encode_timestamp(v)] end,
      decode_binary: lift(&Primitive.decode_timestamp/1),
      type_descriptor: fn -> primitive_td(:timestamp) end
    }
  end

  # ---- optional(T) ----

  def optional(%TypeAdapter{} = inner) do
    %TypeAdapter{
      is_default: &is_nil/1,
      to_json: fn
        nil, _ -> nil
        v, flavor -> inner.to_json.(v, flavor)
      end,
      decode_json: fn
        nil, _, _ -> nil
        0, _, _ -> nil
        v, path, keep -> inner.decode_json.(v, path, keep)
      end,
      encode_binary: fn
        nil, acc -> [acc, <<0xFF>>]
        v, acc -> inner.encode_binary.(v, [acc, <<0x01>>])
      end,
      decode_binary: fn
        <<0x00, r::bits>>, _keep ->
          {:ok, {nil, r}}

        <<0xFF, r::bits>>, _keep ->
          {:ok, {nil, r}}

        <<0x01, r::bits>>, keep ->
          inner.decode_binary.(r, keep)

        <<b, _::bits>>, _keep ->
          {:error, "unexpected optional tag: 0x#{Integer.to_string(b, 16)}"}

        <<>>, _keep ->
          {:error, "unexpected end of input"}
      end,
      type_descriptor: fn -> wrap_optional_td(inner) end
    }
  end

  # ---- list(T) ----

  def list(%TypeAdapter{} = inner) do
    %TypeAdapter{
      is_default: &(&1 == []),
      to_json: fn list, flavor ->
        Enum.map(list, fn v -> inner.to_json.(v, flavor) end)
      end,
      decode_json: fn
        list, path, keep when is_list(list) ->
          list
          |> Enum.with_index()
          |> Enum.map(fn {v, i} ->
            try do
              inner.decode_json.(v, path ++ [i], keep)
            rescue
              e in Skir.DecodeError ->
                reraise Skir.DecodeError.prepend(e, i), __STACKTRACE__
            end
          end)

        _other, _, _ ->
          []
      end,
      encode_binary: fn list, acc -> encode_array_iodata(list, acc, inner) end,
      decode_binary: fn bits, keep -> decode_array(bits, inner, keep) end,
      type_descriptor: fn -> wrap_array_td(inner, "") end
    }
  end

  @doc """
  TypeAdapter for a keyed list: `{:array, T, key: :id}` in the schema.

  Identical wire format to `list/1`, but produces a `%Skir.KeyedList{}`
  on decode and accepts both plain lists and `%KeyedList{}` on encode.
  """
  def keyed_list(%TypeAdapter{} = inner, key_field)
      when is_atom(key_field) or is_list(key_field) do
    %TypeAdapter{
      is_default: fn
        %Skir.KeyedList{items: []} -> true
        [] -> true
        _ -> false
      end,
      to_json: fn
        %Skir.KeyedList{items: items}, flavor ->
          Enum.map(items, fn v -> inner.to_json.(v, flavor) end)

        list, flavor when is_list(list) ->
          Enum.map(list, fn v -> inner.to_json.(v, flavor) end)
      end,
      decode_json: fn
        list, path, keep when is_list(list) ->
          items =
            list
            |> Enum.with_index()
            |> Enum.map(fn {v, i} ->
              try do
                inner.decode_json.(v, path ++ [i], keep)
              rescue
                e in Skir.DecodeError ->
                  reraise Skir.DecodeError.prepend(e, i), __STACKTRACE__
              end
            end)

          Skir.KeyedList.new(items, key_field)

        _other, _, _ ->
          Skir.KeyedList.empty(key_field)
      end,
      encode_binary: fn
        %Skir.KeyedList{items: items}, acc ->
          encode_array_iodata(items, acc, inner)

        list, acc when is_list(list) ->
          encode_array_iodata(list, acc, inner)
      end,
      decode_binary: fn bits, keep ->
        case decode_array(bits, inner, keep) do
          {:ok, {items, rest}} -> {:ok, {Skir.KeyedList.new(items, key_field), rest}}
          {:error, _} = err -> err
        end
      end,
      type_descriptor: fn -> wrap_array_td(inner, key_extractor_str(key_field)) end
    }
  end

  # Shared by list/1 and keyed_list/2 for binary encoding.
  defp encode_array_iodata(items, acc, inner) do
    n = length(items)
    acc2 = [acc, encode_array_header(n)]
    Enum.reduce(items, acc2, fn v, a -> inner.encode_binary.(v, a) end)
  end

  # Array binary encoding: same headers as struct (0/0xF6=0, 0xF7/8/9=1/2/3, 0xFA+len for more).
  defp encode_array_header(0), do: <<0xF6>>
  defp encode_array_header(1), do: <<0xF7>>
  defp encode_array_header(2), do: <<0xF8>>
  defp encode_array_header(3), do: <<0xF9>>
  defp encode_array_header(n) when n > 3, do: [0xFA, Number.encode_uint32(n)]

  defp decode_array(<<0x00, r::bits>>, _inner, _keep), do: {:ok, {[], r}}
  defp decode_array(<<0xF6, r::bits>>, _inner, _keep), do: {:ok, {[], r}}
  defp decode_array(<<0xF7, r::bits>>, inner, keep), do: decode_array_items(r, inner, 1, [], keep)
  defp decode_array(<<0xF8, r::bits>>, inner, keep), do: decode_array_items(r, inner, 2, [], keep)
  defp decode_array(<<0xF9, r::bits>>, inner, keep), do: decode_array_items(r, inner, 3, [], keep)

  defp decode_array(<<0xFA, r::bits>>, inner, keep) do
    case Number.decode_uint32(r) do
      {:ok, {n, r2}} -> decode_array_items(r2, inner, n, [], keep)
      {:error, _} = err -> err
    end
  end

  defp decode_array(<<b, _::bits>>, _, _),
    do: {:error, "unexpected array header: 0x#{Integer.to_string(b, 16)}"}

  defp decode_array(<<>>, _, _), do: {:error, "unexpected end of input"}

  defp decode_array_items(bits, _inner, 0, acc, _keep), do: {:ok, {Enum.reverse(acc), bits}}

  defp decode_array_items(bits, inner, n, acc, keep) do
    case inner.decode_binary.(bits, keep) do
      {:ok, {v, rest}} -> decode_array_items(rest, inner, n - 1, [v | acc], keep)
      {:error, _} = err -> err
    end
  end

  # ---- helpers ----

  # defp raise_type_mismatch(expected, got, path) do
  #   raise DecodeError, path: path, expected: expected, got: got, reason: :type_mismatch
  # end

  # defp raise_out_of_range(expected, got, path) do
  #   raise DecodeError, path: path, expected: expected, got: got, reason: :out_of_range
  # end

  # defp parse_int!(s, type, path) do
  #   case Integer.parse(s) do
  #     {n, ""} -> n
  #     _ -> raise_type_mismatch(type, s, path)
  #   end
  # end

  # Lenient parse: tries integer parse, then float (rounded), then default 0.
  defp parse_int_lenient(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(s) do
          {f, ""} -> trunc(f)
          _ -> 0
        end
    end
  end

  # Lenient float parse: float → float, integer → float, else 0.0.
  defp parse_float_lenient(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} ->
        f

      _ ->
        case Integer.parse(s) do
          {n, ""} -> n * 1.0
          _ -> 0.0
        end
    end
  end

  # Safe conversion from unix millis to DateTime, returning epoch on overflow.
  @epoch ~U[1970-01-01 00:00:00.000Z]
  defp from_unix_ms_safe(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> dt
      _ -> @epoch
    end
  end

  defp primitive_td(p) do
    %TypeDescriptor{type_sig: {:primitive, p}, records: %{}}
  end

  defp wrap_optional_td(inner) do
    inner_td = inner.type_descriptor.()
    %TypeDescriptor{type_sig: {:optional, inner_td.type_sig}, records: inner_td.records}
  end

  defp wrap_array_td(inner, key_extractor) do
    inner_td = inner.type_descriptor.()

    %TypeDescriptor{
      type_sig: {:array, inner_td.type_sig, key_extractor},
      records: inner_td.records
    }
  end

  # key path [:sub_item, :weekday, :kind] -> "sub_item.weekday.kind"
  # single atom :id -> "id"
  defp key_extractor_str(key_field) when is_atom(key_field), do: Atom.to_string(key_field)

  defp key_extractor_str(key_field) when is_list(key_field) do
    Enum.map_join(key_field, ".", &Atom.to_string/1)
  end
end
