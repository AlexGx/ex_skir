defmodule Skir.Enum.Codegen do
  @moduledoc false
  # Compile-time code generation for Skir enums, mirroring Skir.Struct.Codegen.
  #
  # Generates (no persistent_term, no closures):
  #   * default/0                    -> :unknown
  #   * __skir_is_default__/1        -> :unknown is default
  #   * __skir_encode_binary__/2
  #   * __skir_decode_binary__/2
  #   * __skir_to_dense_json__/1, __skir_to_readable_json__/1
  #   * __skir_decode_json__/3
  #   * __skir_type_descriptor__/0
  #
  # Runtime representation:
  #   constant variant -> bare atom (:free)
  #   wrapper variant  -> {:name, payload}
  #   :unknown / {:unknown, %Skir.Unrecognized{}}
  #
  # Wrapper payload types reuse Skir.Struct.TypeResolver (same AST fragments
  # for encode/decode/json/type_sig as struct fields).

  alias Skir.Struct.TypeResolver

  @doc """
  Generate all enum codegen functions. `meta` carries module_path,
  qualified_name, doc. Returns a quoted block for __before_compile__.
  """
  def generate(variants, removed, meta) do
    quote do
      unquote(gen_default())
      unquote(gen_is_default())
      unquote(gen_encode_binary(variants))
      unquote(gen_decode_binary(variants, removed))
      unquote(gen_to_json(variants))
      unquote(gen_decode_json(variants, removed))
      unquote(gen_type_descriptor(variants, removed, meta))
    end
  end

  # ===========================================================================
  # default/0 + __skir_is_default__/1
  # ===========================================================================

  defp gen_default do
    quote do
      def default, do: :unknown
    end
  end

  defp gen_is_default do
    quote do
      def __skir_is_default__(:unknown), do: true
      def __skir_is_default__(_), do: false
    end
  end

  # ===========================================================================
  # __skir_encode_binary__/2
  # ===========================================================================
  #
  #   :unknown                                  -> <<0x00>>
  #   {:unknown, %Unrecognized{format: :binary}} -> re-emit captured bytes
  #   constant atom                              -> uint32(number)
  #   {name, payload} wrapper                    -> header + inner encode
  #
  # Header: n in 1..4 -> <<0xFA + n>> ; else [<<0xF8>>, uint32(n)]

  defp gen_encode_binary(variants) do
    constant_clauses =
      for %{kind: :constant, name: name, number: n} <- variants do
        quote do
          def __skir_encode_binary__(unquote(name), acc) do
            [acc, Skir.Wire.Number.encode_uint32(unquote(n))]
          end
        end
      end

    wrapper_clauses =
      for %{kind: :wrapper, name: name, number: n, wraps: w} <- variants do
        header_ast = wrapper_header_ast(n)
        payload_encode = TypeResolver.encode_binary_ast(w, quote(do: payload))

        quote do
          def __skir_encode_binary__({unquote(name), payload}, acc) do
            [acc, unquote(header_ast), unquote(payload_encode)]
          end
        end
      end

    quote do
      def __skir_encode_binary__(:unknown, acc), do: [acc, <<0x00>>]

      def __skir_encode_binary__(
            {:unknown, %Skir.Unrecognized{format: :binary, data: bytes}},
            acc
          ) do
        [acc, bytes]
      end

      unquote_splicing(constant_clauses)
      unquote_splicing(wrapper_clauses)

      # Any unrecognized atom/tuple falls back to :unknown encoding.
      def __skir_encode_binary__(_other, acc), do: [acc, <<0x00>>]
    end
  end

  # Compile-time header: 1..4 -> single byte 0xFB..0xFE; else 0xF8 + uint32.
  defp wrapper_header_ast(n) when n >= 1 and n <= 4, do: <<0xFA + n>>

  defp wrapper_header_ast(n) do
    quote do
      [<<0xF8>>, Skir.Wire.Number.encode_uint32(unquote(n))]
    end
  end

  # ===========================================================================
  # __skir_decode_binary__/2
  # ===========================================================================
  #
  # Context dispatch by first byte (mirrors Compiler.enum_decode_binary):
  #   wire < 0xF2        -> constant context: decode_uint32 -> resolve
  #   wire in 0xFB..0xFE -> wrapper short: n = wire - 0xFA
  #   wire == 0xF8       -> wrapper long: uint32 n + payload
  #   else               -> skip + :unknown

  defp gen_decode_binary(variants, removed) do
    constant_resolve = gen_resolve_constant(variants, removed)
    wrapper_resolve = gen_decode_wrapper(variants, removed)

    quote do
      def __skir_decode_binary__(<<wire, _::bits>> = bits, keep) when wire < 0xF2 do
        case Skir.Wire.Number.decode_uint32(bits) do
          {:ok, {0, rest}} ->
            {:ok, {:unknown, rest}}

          {:ok, {n, rest}} ->
            __skir_resolve_constant__(n, bits, rest, keep)

          {:error, _} = err ->
            err
        end
      end

      def __skir_decode_binary__(<<wire, payload::bits>> = bits, keep)
          when wire in 0xFB..0xFE do
        n = wire - 0xFA
        __skir_decode_wrapper__(n, payload, bits, keep)
      end

      def __skir_decode_binary__(<<0xF8, after_header::bits>> = bits, keep) do
        case Skir.Wire.Number.decode_uint32(after_header) do
          {:ok, {n, payload}} -> __skir_decode_wrapper__(n, payload, bits, keep)
          {:error, _} = err -> err
        end
      end

      def __skir_decode_binary__(<<_, _::bits>> = bits, _keep) do
        case Skir.Wire.Skip.skip_value(bits) do
          {:ok, rest} -> {:ok, {:unknown, rest}}
          {:error, _} = err -> err
        end
      end

      def __skir_decode_binary__(<<>>, _keep) do
        {:error, "unexpected end of input decoding enum"}
      end

      unquote(constant_resolve)
      unquote(wrapper_resolve)
    end
  end

  # __skir_resolve_constant__(n, original_bits, rest, keep)
  # Maps a decoded variant number (constant context) to a value.
  defp gen_resolve_constant(variants, removed) do
    # Per-number clauses for known variants.
    number_clauses =
      for v <- variants do
        case v.kind do
          :constant ->
            quote do
              def __skir_resolve_constant__(unquote(v.number), _bits, rest, _keep) do
                {:ok, {unquote(v.name), rest}}
              end
            end

          :wrapper ->
            # Wire is constant-form but variant is a wrapper in schema:
            # yield {name, default_payload}.
            default_payload = default_payload_ast(v.wraps)

            quote do
              def __skir_resolve_constant__(unquote(v.number), _bits, rest, _keep) do
                {:ok, {{unquote(v.name), unquote(default_payload)}, rest}}
              end
            end
        end
      end

    removed_clauses =
      for n <- removed do
        quote do
          def __skir_resolve_constant__(unquote(n), _bits, rest, _keep) do
            {:ok, {:unknown, rest}}
          end
        end
      end

    quote do
      unquote_splicing(number_clauses)
      unquote_splicing(removed_clauses)

      # Truly unknown variant number: keep -> capture, drop -> :unknown.
      def __skir_resolve_constant__(_n, bits, rest, :keep) do
        Skir.Enum.Codegen.capture_unknown(bits, rest)
      end

      def __skir_resolve_constant__(_n, _bits, rest, :drop) do
        {:ok, {:unknown, rest}}
      end
    end
  end

  # __skir_decode_wrapper__(n, payload_bits, original_bits, keep)
  defp gen_decode_wrapper(variants, removed) do
    number_clauses =
      for v <- variants do
        case v.kind do
          :wrapper ->
            payload_decode =
              TypeResolver.decode_binary_ast(v.wraps, quote(do: payload_bits), quote(do: keep))

            quote do
              def __skir_decode_wrapper__(unquote(v.number), payload_bits, _bits, keep) do
                case unquote(payload_decode) do
                  {:ok, {val, rest}} -> {:ok, {{unquote(v.name), val}, rest}}
                  {:error, _} = err -> err
                end
              end
            end

          :constant ->
            # Wire is wrapper-form but variant is constant in schema:
            # take constant, skip payload.
            quote do
              def __skir_decode_wrapper__(unquote(v.number), payload_bits, _bits, _keep) do
                case Skir.Wire.Skip.skip_value(payload_bits) do
                  {:ok, rest} -> {:ok, {unquote(v.name), rest}}
                  {:error, _} = err -> err
                end
              end
            end
        end
      end

    removed_clauses =
      for n <- removed do
        quote do
          def __skir_decode_wrapper__(unquote(n), payload_bits, _bits, _keep) do
            case Skir.Wire.Skip.skip_value(payload_bits) do
              {:ok, rest} -> {:ok, {:unknown, rest}}
              {:error, _} = err -> err
            end
          end
        end
      end

    quote do
      unquote_splicing(number_clauses)
      unquote_splicing(removed_clauses)

      # Truly unknown wrapper variant: skip payload, keep -> capture.
      def __skir_decode_wrapper__(_n, payload_bits, bits, keep) do
        case Skir.Wire.Skip.skip_value(payload_bits) do
          {:ok, rest} ->
            if keep == :keep do
              Skir.Enum.Codegen.capture_unknown(bits, rest)
            else
              {:ok, {:unknown, rest}}
            end

          {:error, _} = err ->
            err
        end
      end
    end
  end

  # ===========================================================================
  # JSON (to_dense, to_readable, decode_json)
  # ===========================================================================

  defp gen_to_json(variants) do
    quote do
      unquote(gen_to_dense_json(variants))
      unquote(gen_to_readable_json(variants))
    end
  end

  defp gen_to_dense_json(variants) do
    constant_clauses =
      for %{kind: :constant, name: name, number: n} <- variants do
        quote(do: def(__skir_to_dense_json__(unquote(name)), do: unquote(n)))
      end

    wrapper_clauses =
      for %{kind: :wrapper, name: name, number: n, wraps: w} <- variants do
        payload_json = TypeResolver.to_json_dense_ast(w, quote(do: payload))

        quote do
          def __skir_to_dense_json__({unquote(name), payload}) do
            [unquote(n), unquote(payload_json)]
          end
        end
      end

    quote do
      def __skir_to_dense_json__(:unknown), do: 0

      def __skir_to_dense_json__({:unknown, %Skir.Unrecognized{format: :json, data: term}}) do
        term
      end

      def __skir_to_dense_json__({:unknown, %Skir.Unrecognized{format: :binary}}), do: 0

      unquote_splicing(constant_clauses)
      unquote_splicing(wrapper_clauses)

      def __skir_to_dense_json__(_other), do: 0
    end
  end

  defp gen_to_readable_json(variants) do
    constant_clauses =
      for %{kind: :constant, name: name} <- variants do
        name_str = Atom.to_string(name)
        quote(do: def(__skir_to_readable_json__(unquote(name)), do: unquote(name_str)))
      end

    wrapper_clauses =
      for %{kind: :wrapper, name: name, wraps: w} <- variants do
        name_str = Atom.to_string(name)
        payload_json = TypeResolver.to_json_readable_ast(w, quote(do: payload))

        quote do
          def __skir_to_readable_json__({unquote(name), payload}) do
            %{"kind" => unquote(name_str), "value" => unquote(payload_json)}
          end
        end
      end

    quote do
      def __skir_to_readable_json__(:unknown), do: "unknown"

      def __skir_to_readable_json__({:unknown, %Skir.Unrecognized{format: :json, data: term}}) do
        term
      end

      def __skir_to_readable_json__({:unknown, %Skir.Unrecognized{format: :binary}}),
        do: "unknown"

      unquote_splicing(constant_clauses)
      unquote_splicing(wrapper_clauses)

      def __skir_to_readable_json__(_other), do: "unknown"
    end
  end

  defp gen_decode_json(variants, removed) do
    # Integer (dense) clauses: removed -> unknown; constant -> name;
    # wrapper -> {name, default_payload}.
    int_removed =
      for n <- removed do
        quote(do: def(__skir_decode_json__(unquote(n), _path, _keep), do: :unknown))
      end

    int_known =
      for v <- variants do
        case v.kind do
          :constant ->
            quote(
              do: def(__skir_decode_json__(unquote(v.number), _path, _keep), do: unquote(v.name))
            )

          :wrapper ->
            default_payload = default_payload_ast(v.wraps)

            quote do
              def __skir_decode_json__(unquote(v.number), _path, _keep) do
                {unquote(v.name), unquote(default_payload)}
              end
            end
        end
      end

    # [n, payload] (wrapper-form) clauses.
    list_removed =
      for n <- removed do
        quote(do: def(__skir_decode_json__([unquote(n), _p], _path, _keep), do: :unknown))
      end

    list_known =
      for v <- variants do
        case v.kind do
          :wrapper ->
            payload_decode =
              Skir.Struct.TypeResolver.decode_json_ast(
                v.wraps,
                quote(do: payload),
                quote(do: path),
                quote(do: keep)
              )

            quote do
              def __skir_decode_json__([unquote(v.number), payload], path, keep) do
                {unquote(v.name), unquote(payload_decode)}
              end
            end

          :constant ->
            quote do
              def __skir_decode_json__([unquote(v.number), _p], _path, _keep) do
                unquote(v.name)
              end
            end
        end
      end

    # %{"kind","value"} (readable wrapper-form) clauses.
    map_known =
      for %{kind: :wrapper, name: name, wraps: w} <- variants do
        name_str = Atom.to_string(name)

        payload_decode =
          Skir.Struct.TypeResolver.decode_json_ast(
            w,
            quote(do: value),
            quote(do: path),
            quote(do: keep)
          )

        quote do
          def __skir_decode_json__(%{"kind" => unquote(name_str), "value" => value}, path, keep) do
            {unquote(name), unquote(payload_decode)}
          end
        end
      end

    string_lookup = gen_string_to_variant(variants)

    quote do
      # 0 is always :unknown.
      def __skir_decode_json__(0, _path, _keep), do: :unknown

      # specific integer variants (removed before known is irrelevant — disjoint)
      unquote_splicing(int_removed)
      unquote_splicing(int_known)

      # any other integer -> unknown (capture if keep)
      def __skir_decode_json__(n, _path, keep) when is_integer(n) do
        Skir.Enum.Codegen.json_unknown_value(n, keep)
      end

      # [n, payload] variants
      unquote_splicing(list_removed)
      unquote_splicing(list_known)

      # any other [n, payload] -> unknown
      def __skir_decode_json__([n, _p] = term, _path, keep) when is_integer(n) do
        Skir.Enum.Codegen.json_unknown_value(term, keep)
      end

      # %{"kind","value"} wrapper variants
      unquote_splicing(map_known)

      # unknown kind in readable object form -> unknown
      def __skir_decode_json__(%{"kind" => _k, "value" => _v}, _path, _keep), do: :unknown

      # string -> constant variant by case-insensitive name
      def __skir_decode_json__(s, _path, _keep) when is_binary(s) do
        __skir_string_to_variant__(String.downcase(s))
      end

      def __skir_decode_json__(_other, _path, _keep), do: :unknown

      # private string lookup
      unquote_splicing(string_lookup)
      defp __skir_string_to_variant__(_), do: :unknown
    end
  end

  # Generates private __skir_string_to_variant__/1 clauses (lowercased name -> atom).
  defp gen_string_to_variant(variants) do
    for %{kind: :constant, name: name} <- variants do
      down = name |> Atom.to_string() |> String.downcase()
      quote(do: defp(__skir_string_to_variant__(unquote(down)), do: unquote(name)))
    end
  end

  # ===========================================================================
  # __skir_type_descriptor__/0
  # ===========================================================================

  defp gen_type_descriptor(variants, removed, meta) do
    id = meta.module_path <> ":" <> meta.qualified_name
    self_id = id
    name = meta.qualified_name |> String.split(".") |> List.last()

    variant_descs_ast =
      Enum.map(variants, fn v ->
        name_str = Atom.to_string(v.name)
        vdoc = v.doc || ""

        case v.kind do
          :constant ->
            quote do
              %Skir.TypeDescriptor.EnumVariant{
                kind: :constant,
                name: unquote(name_str),
                number: unquote(v.number),
                doc: unquote(vdoc)
              }
            end

          :wrapper ->
            sig_ast = TypeResolver.type_sig_ast(v.wraps, self_id)

            quote do
              %Skir.TypeDescriptor.EnumVariant{
                kind: :wrapper,
                name: unquote(name_str),
                number: unquote(v.number),
                variant_type: unquote(sig_ast),
                doc: unquote(vdoc)
              }
            end
        end
      end)

    wrapper_records_asts =
      for %{kind: :wrapper, wraps: w} <- variants do
        TypeResolver.field_records_ast(w, self_id)
      end

    merged_records_ast =
      Enum.reduce(wrapper_records_asts, quote(do: %{}), fn rec_ast, acc ->
        quote(do: Map.merge(unquote(acc), unquote(rec_ast)))
      end)

    quote do
      def __skir_type_descriptor__ do
        ed = %Skir.TypeDescriptor.EnumDescriptor{
          name: unquote(name),
          qualified_name: unquote(meta.qualified_name),
          module_path: unquote(meta.module_path),
          doc: unquote(meta.doc || ""),
          removed_numbers: unquote(Macro.escape(removed)),
          variants: unquote(variant_descs_ast)
        }

        all_records = unquote(merged_records_ast)
        records = Map.put(all_records, unquote(id), {:enum, ed})

        %Skir.TypeDescriptor{type_sig: {:record, unquote(id)}, records: records}
      end
    end
  end

  # ===========================================================================
  # Runtime helpers
  # ===========================================================================

  @doc false
  def capture_unknown(original_bits, rest) do
    consumed = byte_size(original_bits) - byte_size(rest)
    <<captured::binary-size(consumed), _::bits>> = original_bits
    {:ok, {{:unknown, %Skir.Unrecognized{format: :binary, data: captured}}, rest}}
  end

  @doc false
  def json_unknown_value(term, :keep),
    do: {:unknown, %Skir.Unrecognized{format: :json, data: term}}

  def json_unknown_value(_term, :drop), do: :unknown

  # Default payload AST for a wrapper variant's inner type (used when wire is
  # constant-form but schema variant is a wrapper). Mirrors default_for_inner.
  defp default_payload_ast(:bool), do: false
  defp default_payload_ast(:int32), do: 0
  defp default_payload_ast(:int64), do: 0
  defp default_payload_ast(:hash64), do: 0
  defp default_payload_ast(:float32), do: 0.0
  defp default_payload_ast(:float64), do: 0.0
  defp default_payload_ast(:string), do: ""
  defp default_payload_ast(:bytes), do: ""
  defp default_payload_ast(:timestamp), do: quote(do: ~U[1970-01-01 00:00:00.000Z])
  defp default_payload_ast(mod) when is_atom(mod), do: quote(do: unquote(mod).default())
end
