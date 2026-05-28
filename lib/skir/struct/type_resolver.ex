defmodule Skir.Struct.TypeResolver do
  @moduledoc false
  # Maps a field's schema type to quoted AST fragments for the generated
  # serialization functions. Centralises the per-type knowledge so the
  # Codegen orchestrator stays focused on struct-level layout.
  #
  # Stage 3 implements `encode_binary_ast/2` (binary encoding). Later stages
  # will add decode_binary_ast, to_json_ast, decode_json_ast, type_sig_ast.
  #
  # Each function takes the field type and a quoted expression that evaluates
  # to the field's value (`value_ast`), and returns quoted AST producing the
  # appropriate iodata / value. Recursion and other-module references are
  # emitted as direct calls to `Mod.__skir_encode_binary__/2`.

  alias Skir.Wire.Number
  alias Skir.Wire.Primitive

  # ===========================================================================
  # encode_binary_ast/2
  # ===========================================================================
  #
  # Returns AST that encodes `value_ast` to iodata (a binary or nested list).
  # Mirrors the runtime Builtin encoders byte-for-byte.

  # --- primitives → direct Wire calls ---

  def encode_binary_ast(:bool, value_ast),
    do: quote(do: Primitive.encode_bool(unquote(value_ast)))

  def encode_binary_ast(:int32, value_ast),
    do: quote(do: Number.encode_int32(unquote(value_ast)))

  def encode_binary_ast(:int64, value_ast),
    do: quote(do: Number.encode_int64(unquote(value_ast)))

  def encode_binary_ast(:hash64, value_ast),
    do: quote(do: Number.encode_hash64(unquote(value_ast)))

  def encode_binary_ast(:float32, value_ast),
    do: quote(do: Primitive.encode_float32(unquote(value_ast)))

  def encode_binary_ast(:float64, value_ast),
    do: quote(do: Primitive.encode_float64(unquote(value_ast)))

  def encode_binary_ast(:string, value_ast),
    do: quote(do: Primitive.encode_string(unquote(value_ast)))

  def encode_binary_ast(:bytes, value_ast),
    do: quote(do: Primitive.encode_bytes(unquote(value_ast)))

  def encode_binary_ast(:timestamp, value_ast),
    do: quote(do: Primitive.encode_timestamp(unquote(value_ast)))

  # --- optional(T): nil → 0xFF; else tag 0x01 + inner encode ---

  def encode_binary_ast({:optional, inner}, value_ast) do
    inner_encode = encode_binary_ast(inner, quote(do: x))

    quote do
      case unquote(value_ast) do
        nil -> <<0xFF>>
        x -> [<<0x01>>, unquote(inner_encode)]
      end
    end
  end

  # --- array(T): header + each item encoded in order ---

  def encode_binary_ast({:array, inner}, value_ast) do
    item_encode = encode_binary_ast(inner, quote(do: item))

    quote do
      list = unquote(value_ast)
      n = length(list)

      [
        Skir.Struct.TypeResolver.array_header(n),
        Enum.map(list, fn item -> unquote(item_encode) end)
      ]
    end
  end

  # --- keyed array(T, key): same wire as array; accept KeyedList or list ---

  def encode_binary_ast({:array, inner, opts}, value_ast) when is_list(opts) do
    item_encode = encode_binary_ast(inner, quote(do: item))

    quote do
      items =
        case unquote(value_ast) do
          %Skir.KeyedList{items: its} -> its
          list when is_list(list) -> list
        end

      n = length(items)

      [
        Skir.Struct.TypeResolver.array_header(n),
        Enum.map(items, fn item -> unquote(item_encode) end)
      ]
    end
  end

  # --- record (other module or self-recursive) ---

  def encode_binary_ast(mod, value_ast) when is_atom(mod) do
    # Direct call to the referenced module's generated encoder. For
    # self-recursive fields this is `__MODULE__.__skir_encode_binary__`,
    # resolved at runtime — no build cycle. The lazy-default sentinel
    # (empty recursive struct) encodes as the empty-struct header 0xF6.
    quote do
      case unquote(value_ast) do
        {:__lazy_default__, _} ->
          <<0xF6>>

        v ->
          unquote(mod).__skir_encode_binary__(v, [])
      end
    end
  end

  # ===========================================================================
  # decode_binary_ast/2
  # ===========================================================================
  #
  # Returns AST evaluating to `{:ok, {value, rest}}` | `{:error, reason}`,
  # given a quoted `bits_ast` (the remaining input) and `keep_ast` (the
  # :keep | :drop flag). Mirrors the runtime Builtin decoders.
  #
  # Primitives ignore keep. Composite/record types thread keep through.

  # --- primitives → direct Wire calls (1-arg, keep ignored) ---

  def decode_binary_ast(:bool, bits_ast, _keep),
    do: quote(do: Primitive.decode_bool(unquote(bits_ast)))

  def decode_binary_ast(:int32, bits_ast, _keep),
    do: quote(do: Number.decode_int32(unquote(bits_ast)))

  def decode_binary_ast(:int64, bits_ast, _keep),
    do: quote(do: Number.decode_int64(unquote(bits_ast)))

  def decode_binary_ast(:hash64, bits_ast, _keep),
    do: quote(do: Number.decode_hash64(unquote(bits_ast)))

  def decode_binary_ast(:float32, bits_ast, _keep),
    do: quote(do: Primitive.decode_float32(unquote(bits_ast)))

  def decode_binary_ast(:float64, bits_ast, _keep),
    do: quote(do: Primitive.decode_float64(unquote(bits_ast)))

  def decode_binary_ast(:string, bits_ast, _keep),
    do: quote(do: Primitive.decode_string(unquote(bits_ast)))

  def decode_binary_ast(:bytes, bits_ast, _keep),
    do: quote(do: Primitive.decode_bytes(unquote(bits_ast)))

  def decode_binary_ast(:timestamp, bits_ast, _keep),
    do: quote(do: Primitive.decode_timestamp(unquote(bits_ast)))

  # --- optional(T): 0x00/0xFF -> nil; 0x01 -> inner decode ---

  def decode_binary_ast({:optional, inner}, bits_ast, keep_ast) do
    inner_decode = decode_binary_ast(inner, quote(do: r), keep_ast)

    quote do
      case unquote(bits_ast) do
        <<0x00, r::bits>> -> {:ok, {nil, r}}
        <<0xFF, r::bits>> -> {:ok, {nil, r}}
        <<0x01, r::bits>> -> unquote(inner_decode)
        <<b, _::bits>> -> {:error, "unexpected optional tag: 0x" <> Integer.to_string(b, 16)}
        <<>> -> {:error, "unexpected end of input"}
      end
    end
  end

  # --- array(T): decode header + N items via runtime helper ---

  def decode_binary_ast({:array, inner}, bits_ast, keep_ast) do
    # We pass a decoder closure to the runtime helper. The closure wraps the
    # inner type's decode AST. This is the one place we use a closure in the
    # generated decode path; arrays are inherently variable-length so a
    # runtime loop is needed regardless.
    item_decoder =
      quote(do: fn b, k -> unquote(decode_binary_ast(inner, quote(do: b), quote(do: k))) end)

    quote do
      Skir.Struct.TypeResolver.decode_array(
        unquote(bits_ast),
        unquote(item_decoder),
        unquote(keep_ast)
      )
    end
  end

  # --- keyed array(T, key): same, then wrap in KeyedList ---

  def decode_binary_ast({:array, inner, opts}, bits_ast, keep_ast) when is_list(opts) do
    key_field = Keyword.get(opts, :key)

    item_decoder =
      quote(do: fn b, k -> unquote(decode_binary_ast(inner, quote(do: b), quote(do: k))) end)

    quote do
      case Skir.Struct.TypeResolver.decode_array(
             unquote(bits_ast),
             unquote(item_decoder),
             unquote(keep_ast)
           ) do
        {:ok, {items, rest}} ->
          {:ok, {Skir.KeyedList.new(items, unquote(key_field)), rest}}

        {:error, _} = err ->
          err
      end
    end
  end

  # --- record (other module or self-recursive) ---

  def decode_binary_ast(mod, bits_ast, keep_ast) when is_atom(mod) do
    quote do
      unquote(mod).__skir_decode_binary__(unquote(bits_ast), unquote(keep_ast))
    end
  end

  # ===========================================================================
  # Runtime helpers (called from generated code)
  # ===========================================================================

  @doc """
  Array/list header: same wire as struct slot count.
  0 → 0xF6, 1 → 0xF7, 2 → 0xF8, 3 → 0xF9, n>3 → [0xFA, uint32(n)].
  """
  def array_header(0), do: <<0xF6>>
  def array_header(1), do: <<0xF7>>
  def array_header(2), do: <<0xF8>>
  def array_header(3), do: <<0xF9>>
  def array_header(n) when n > 3, do: [0xFA, Number.encode_uint32(n)]

  @doc """
  Decode an array given a 2-arg item decoder `fn bits, keep -> {:ok, {v, rest}} | {:error, _}`.
  Returns `{:ok, {items_list, rest}}` | `{:error, reason}`. Same wire as Builtin.decode_array.
  """
  def decode_array(<<0x00, r::bits>>, _decoder, _keep), do: {:ok, {[], r}}
  def decode_array(<<0xF6, r::bits>>, _decoder, _keep), do: {:ok, {[], r}}

  def decode_array(<<0xF7, r::bits>>, decoder, keep),
    do: decode_array_items(r, decoder, 1, [], keep)

  def decode_array(<<0xF8, r::bits>>, decoder, keep),
    do: decode_array_items(r, decoder, 2, [], keep)

  def decode_array(<<0xF9, r::bits>>, decoder, keep),
    do: decode_array_items(r, decoder, 3, [], keep)

  def decode_array(<<0xFA, r::bits>>, decoder, keep) do
    case Number.decode_uint32(r) do
      {:ok, {n, r2}} -> decode_array_items(r2, decoder, n, [], keep)
      {:error, _} = err -> err
    end
  end

  def decode_array(<<b, _::bits>>, _, _),
    do: {:error, "unexpected array header: 0x" <> Integer.to_string(b, 16)}

  def decode_array(<<>>, _, _), do: {:error, "unexpected end of input"}

  defp decode_array_items(bits, _decoder, 0, acc, _keep), do: {:ok, {Enum.reverse(acc), bits}}

  defp decode_array_items(bits, decoder, n, acc, keep) do
    case decoder.(bits, keep) do
      {:ok, {v, rest}} -> decode_array_items(rest, decoder, n - 1, [v | acc], keep)
      {:error, _} = err -> err
    end
  end
end
