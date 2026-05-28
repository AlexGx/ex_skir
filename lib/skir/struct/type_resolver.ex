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
end
