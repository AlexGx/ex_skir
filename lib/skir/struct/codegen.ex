defmodule Skir.Struct.Codegen do
  @moduledoc false
  # Compile-time code generation for Skir structs.
  #
  # Stages:
  #   Stage 1 — __skir_is_default__/1, __skir_highest_non_default__/1
  #   Stage 2 — default/0, __skir_defaults_map__/0  (no persistent_term)
  #   Stage 3 — __skir_encode_binary__/2            (generated alongside;
  #             to_binary/1 not switched until diff-tested)


  @doc """
  Generates all codegen-managed functions for a struct module.
  Returns a quoted block to splice into the module body via `__before_compile__`.
  """
  def generate(fields) do
    quote do
      unquote(gen_is_default(fields))
      unquote(gen_highest_non_default(fields))
      unquote(gen_default(fields))
      unquote(gen_defaults_map(fields))
      unquote(gen_encode_binary(fields))
      unquote(gen_decode_binary(fields))
      unquote(gen_to_json(fields))
      unquote(gen_decode_json(fields))
    end
  end

  # ===========================================================================
  # Stage 1: __skir_is_default__/1
  # ===========================================================================

  defp gen_is_default(fields) do
    {pattern_fields, runtime_check_fields} =
      Enum.split_with(fields, fn f -> primitive_default_pattern?(f.type) end)

    pattern_pairs =
      Enum.map(pattern_fields, fn f ->
        {f.name, primitive_default_pattern(f.type)}
      end)

    pattern_pairs = [{:__skir_unrecognized__, nil} | pattern_pairs]

    if runtime_check_fields == [] do
      quote do
        def __skir_is_default__(%__MODULE__{unquote_splicing(pattern_pairs)}), do: true
        def __skir_is_default__(_), do: false
      end
    else
      var_bindings =
        Enum.map(runtime_check_fields, fn f ->
          {f.name, Macro.var(f.name, __MODULE__)}
        end)

      all_pattern_pairs = pattern_pairs ++ var_bindings

      body =
        Enum.reduce(runtime_check_fields, true, fn f, acc ->
          check = non_pattern_is_default_check(f.type, Macro.var(f.name, __MODULE__))
          quote(do: unquote(acc) and unquote(check))
        end)

      quote do
        def __skir_is_default__(%__MODULE__{unquote_splicing(all_pattern_pairs)}) do
          unquote(body)
        end

        def __skir_is_default__(_), do: false
      end
    end
  end

  defp primitive_default_pattern?(:bool), do: true
  defp primitive_default_pattern?(:int32), do: true
  defp primitive_default_pattern?(:int64), do: true
  defp primitive_default_pattern?(:hash64), do: true
  defp primitive_default_pattern?(:float32), do: true
  defp primitive_default_pattern?(:float64), do: true
  defp primitive_default_pattern?(:string), do: true
  defp primitive_default_pattern?(:bytes), do: true
  defp primitive_default_pattern?(:timestamp), do: true
  defp primitive_default_pattern?({:optional, _}), do: true
  defp primitive_default_pattern?({:array, _}), do: true
  defp primitive_default_pattern?({:array, _, _}), do: false
  defp primitive_default_pattern?(mod) when is_atom(mod), do: false

  defp primitive_default_pattern(:bool), do: false
  defp primitive_default_pattern(:int32), do: 0
  defp primitive_default_pattern(:int64), do: 0
  defp primitive_default_pattern(:hash64), do: 0
  defp primitive_default_pattern(:float32), do: quote(do: +0.0)
  defp primitive_default_pattern(:float64), do: quote(do: +0.0)
  defp primitive_default_pattern(:string), do: ""
  defp primitive_default_pattern(:bytes), do: ""
  defp primitive_default_pattern(:timestamp), do: quote(do: ~U[1970-01-01 00:00:00.000Z])
  defp primitive_default_pattern({:optional, _}), do: nil
  defp primitive_default_pattern({:array, _}), do: []

  defp non_pattern_is_default_check({:array, _, _}, var) do
    quote do
      unquote(var) == [] or match?(%Skir.KeyedList{items: []}, unquote(var))
    end
  end

  defp non_pattern_is_default_check(mod, var) when is_atom(mod) do
    quote do
      case unquote(var) do
        {:__lazy_default__, _} ->
          true

        v ->
          if function_exported?(unquote(mod), :__skir_is_default__, 1) do
            unquote(mod).__skir_is_default__(v)
          else
            v == unquote(mod).default()
          end
      end
    end
  end

  # ===========================================================================
  # Stage 1: __skir_highest_non_default__/1
  # ===========================================================================

  defp gen_highest_non_default(fields) do
    fields_desc = Enum.sort_by(fields, & &1.number, :desc)
    max_field_num = fields |> Enum.map(& &1.number) |> Enum.max(fn -> -1 end)
    total_slots = max_field_num + 1

    if fields == [] do
      quote do
        def __skir_highest_non_default__(_), do: 0
      end
    else
      cond_clauses = build_cond_clauses(fields_desc)

      quote do
        def __skir_highest_non_default__(%__MODULE__{__skir_unrecognized__: u})
            when not is_nil(u) do
          unquote(total_slots)
        end

        def __skir_highest_non_default__(%__MODULE__{} = s) do
          cond do
            unquote(cond_clauses)
          end
        end

        def __skir_highest_non_default__(_), do: 0
      end
    end
  end

  defp build_cond_clauses(fields_desc) do
    field_clauses =
      Enum.map(fields_desc, fn f ->
        check = non_default_check_for_var(f.type, quote(do: s.unquote(Macro.var(f.name, nil))))
        value = f.number + 1

        quote do
          unquote(check) -> unquote(value)
        end
      end)

    fallback =
      quote do
        true -> 0
      end

    Enum.flat_map(field_clauses ++ [fallback], fn ast ->
      case ast do
        {:->, _, _} = single -> [single]
        list when is_list(list) -> list
        other -> [other]
      end
    end)
  end

  defp non_default_check_for_var(:bool, var), do: quote(do: unquote(var) != false)
  defp non_default_check_for_var(:int32, var), do: quote(do: unquote(var) != 0)
  defp non_default_check_for_var(:int64, var), do: quote(do: unquote(var) != 0)
  defp non_default_check_for_var(:hash64, var), do: quote(do: unquote(var) != 0)

  defp non_default_check_for_var(:float32, var),
    do: quote(do: unquote(var) != +0.0 and unquote(var) != -0.0)

  defp non_default_check_for_var(:float64, var),
    do: quote(do: unquote(var) != +0.0 and unquote(var) != -0.0)

  defp non_default_check_for_var(:string, var), do: quote(do: unquote(var) != "")
  defp non_default_check_for_var(:bytes, var), do: quote(do: unquote(var) != "")

  defp non_default_check_for_var(:timestamp, var),
    do: quote(do: unquote(var) != ~U[1970-01-01 00:00:00.000Z])

  defp non_default_check_for_var({:optional, _}, var),
    do: quote(do: not is_nil(unquote(var)))

  defp non_default_check_for_var({:array, _}, var),
    do: quote(do: unquote(var) != [])

  defp non_default_check_for_var({:array, _, _}, var) do
    quote do
      unquote(var) != [] and not match?(%Skir.KeyedList{items: []}, unquote(var))
    end
  end

  defp non_default_check_for_var(mod, var) when is_atom(mod) do
    quote do
      case unquote(var) do
        {:__lazy_default__, _} ->
          false

        v ->
          if function_exported?(unquote(mod), :__skir_is_default__, 1) do
            not unquote(mod).__skir_is_default__(v)
          else
            v != unquote(mod).default()
          end
      end
    end
  end

  # ===========================================================================
  # Stage 2: default/0
  # ===========================================================================

  defp gen_default(fields) do
    field_pairs =
      Enum.map(fields, fn f ->
        {f.name, default_value_ast(f.type)}
      end)

    quote do
      def default do
        %__MODULE__{unquote_splicing(field_pairs)}
      end
    end
  end

  defp default_value_ast(:bool), do: false
  defp default_value_ast(:int32), do: 0
  defp default_value_ast(:int64), do: 0
  defp default_value_ast(:hash64), do: 0
  defp default_value_ast(:float32), do: 0.0
  defp default_value_ast(:float64), do: 0.0
  defp default_value_ast(:string), do: ""
  defp default_value_ast(:bytes), do: ""

  defp default_value_ast(:timestamp), do: quote(do: ~U[1970-01-01 00:00:00.000Z])

  defp default_value_ast({:optional, _}), do: nil
  defp default_value_ast({:array, _}), do: []

  defp default_value_ast({:array, _inner, opts}) when is_list(opts) do
    case Keyword.get(opts, :key) do
      nil ->
        []

      key_field ->
        quote do
          Skir.KeyedList.empty(unquote(key_field))
        end
    end
  end

  defp default_value_ast(mod) when is_atom(mod) do
    quote do
      if unquote(mod) == __MODULE__ do
        {:__lazy_default__, __MODULE__}
      else
        unquote(mod).default()
      end
    end
  end

  # ===========================================================================
  # Stage 2: __skir_defaults_map__/0
  # ===========================================================================

  defp gen_defaults_map(fields) do
    field_pairs =
      Enum.map(fields, fn f ->
        {f.name, default_value_ast(f.type)}
      end)

    quote do
      def __skir_defaults_map__ do
        %{unquote_splicing(field_pairs)}
      end
    end
  end

  # ===========================================================================
  # Stage 3: __skir_encode_binary__/2
  # ===========================================================================
  #
  # Generated alongside the existing runtime path (to_binary/1 still routes
  # through the Compiler closures until diff-tested). Mirrors
  # Compiler.struct_encode_binary byte-for-byte:
  #
  #   * preserved binary unrecognized -> emit all recognized slots + captured bytes
  #   * normal -> emit highest_non_default slots
  #
  # Approach (D): build the full ordered list of encoded slots, then take the
  # first `count`. Simple and robust; trailing-default slots are still encoded
  # then dropped (optimise later if profiling shows it matters).

  defp gen_encode_binary(fields) do
    positions = build_position_list(fields)
    v = Macro.var(:v, __MODULE__)

    # AST that builds the full list of encoded slots for value `v`.
    all_slots_ast =
      Enum.map(positions, fn pos -> encode_slot_ast(pos, v) end)

    quote do
      def __skir_encode_binary__(
            %__MODULE__{
              __skir_unrecognized__: %Skir.Unrecognized{
                format: :binary,
                data: extra_bytes,
                array_len: total
              }
            } = unquote(v),
            acc
          ) do
        slots = unquote(all_slots_ast)
        [acc, Skir.Wire.Struct.encode_slot_count(total), slots, extra_bytes]
      end

      def __skir_encode_binary__(%__MODULE__{} = unquote(v), acc) do
        count = __skir_highest_non_default__(unquote(v))
        slots = unquote(all_slots_ast)
        [acc, Skir.Wire.Struct.encode_slot_count(count), Enum.take(slots, count)]
      end

      # Lazy-default sentinel (empty recursive struct) -> empty-struct header.
      def __skir_encode_binary__({:__lazy_default__, _}, acc) do
        [acc, <<0xF6>>]
      end
    end
  end

  # Build an ordered list of positions: [:removed | {:field, field_meta}],
  # indexed 0..max_slot. nil-gaps that aren't fields are :removed slots.
  defp build_position_list(fields) do
    by_num = Map.new(fields, &{&1.number, &1})
    max_field = fields |> Enum.map(& &1.number) |> Enum.max(fn -> -1 end)

    if max_field < 0 do
      []
    else
      for i <- 0..max_field do
        case Map.get(by_num, i) do
          nil -> :removed
          f -> {:field, f}
        end
      end
    end
  end

  # AST for encoding a single slot of the struct value (bound to `value_ast`).
  defp encode_slot_ast(:removed, _value_ast), do: quote(do: <<0x00>>)

  defp encode_slot_ast({:field, f}, value_ast) do
    field_access = quote(do: unquote(value_ast).unquote(Macro.var(f.name, nil)))
    Skir.Struct.TypeResolver.encode_binary_ast(f.type, field_access)
  end

  # ===========================================================================
  # Stage 4: __skir_decode_binary__/2  (approach B — unrolled chain)
  # ===========================================================================
  #
  # Generated alongside the existing runtime path (from_binary still routes
  # through Compiler closures until diff-tested). Mirrors
  # Compiler.struct_decode_binary:
  #
  #   1. decode_slot_count -> {count, rest}
  #   2. slots_to_fill = min(count, recognized)
  #   3. chain __skir_decode_s0__ .. __skir_decode_sN__ threads `remaining`,
  #      decoding/skipping each slot, accumulating into the defaults map
  #   4. __skir_finish_decode__ handles extra slots (keep: capture, drop: skip)
  #
  # Each chain function has a `remaining <= 0` guard clause that stops early
  # (when count < recognized) returning the accumulated map + rest.

  defp gen_decode_binary(fields) do
    positions = build_position_list(fields)
    recognized = length(positions)

    if recognized == 0 do
      # No fields: empty struct. Just read the header and finish.
      quote do
        def __skir_decode_binary__(bits, keep) do
          case Skir.Wire.Struct.decode_slot_count(bits) do
            {:ok, {count, rest}} ->
              __skir_finish_decode__(count, rest, __skir_defaults_map__(), count, keep)

            {:error, _} = err ->
              err
          end
        end
      end
      |> wrap_with_finish()
    else
      chain = gen_decode_chain(positions, recognized)

      main =
        quote do
          def __skir_decode_binary__(bits, keep) do
            case Skir.Wire.Struct.decode_slot_count(bits) do
              {:ok, {count, rest}} ->
                slots_to_fill = min(count, unquote(recognized))

                case __skir_decode_s0__(rest, slots_to_fill, __skir_defaults_map__(), keep) do
                  {:ok, {acc, after_recognized}} ->
                    extra = count - slots_to_fill
                    __skir_finish_decode__(extra, after_recognized, acc, count, keep)

                  {:error, _} = err ->
                    err
                end

              {:error, _} = err ->
                err
            end
          end
        end

      quote do
        unquote(main)
        unquote_splicing(chain)
        unquote(gen_finish_decode())
      end
    end
  end

  # For the no-fields case, just emit the finish helper alongside.
  defp wrap_with_finish(main_ast) do
    quote do
      unquote(main_ast)
      unquote(gen_finish_decode())
    end
  end

  # Generates the chain functions __skir_decode_s0__ .. __skir_decode_s{N-1}__.
  # Each: guard `remaining <= 0` -> stop; else decode/skip its slot, recurse
  # to next (or, for the last slot, return the result directly).
  defp gen_decode_chain(positions, recognized) do
    for {pos, idx} <- Enum.with_index(positions) do
      fn_name = :"__skir_decode_s#{idx}__"
      is_last = idx == recognized - 1
      next_name = :"__skir_decode_s#{idx + 1}__"

      decode_body = decode_slot_body(pos, idx, is_last, next_name)

      quote do
        defp unquote(fn_name)(rest, remaining, acc, _keep) when remaining <= 0 do
          {:ok, {acc, rest}}
        end

        defp unquote(fn_name)(rest, remaining, acc, keep) do
          unquote(decode_body)
        end
      end
    end
  end

  # Body of one chain function: decode (or skip) this slot, then continue.
  defp decode_slot_body(:removed, _idx, is_last, next_name) do
    continue =
      if is_last do
        quote(do: {:ok, {acc, r1}})
      else
        quote(do: unquote(next_name)(r1, remaining - 1, acc, keep))
      end

    quote do
      case Skir.Wire.Skip.skip_value(rest) do
        {:ok, r1} -> unquote(continue)
        {:error, _} = err -> err
      end
    end
  end

  defp decode_slot_body({:field, f}, _idx, is_last, next_name) do
    decode_ast = Skir.Struct.TypeResolver.decode_binary_ast(f.type, quote(do: rest), quote(do: keep))
    field_name = f.name

    continue =
      if is_last do
        quote(do: {:ok, {Map.put(acc, unquote(field_name), v), r1}})
      else
        quote(do: unquote(next_name)(r1, remaining - 1, Map.put(acc, unquote(field_name), v), keep))
      end

    quote do
      case unquote(decode_ast) do
        {:ok, {v, r1}} -> unquote(continue)
        {:error, _} = err -> err
      end
    end
  end

  # __skir_finish_decode__/5 — handle extra slots beyond recognized count.
  defp gen_finish_decode do
    quote do
      defp __skir_finish_decode__(0, rest, acc, _count, _keep) do
        {:ok, {struct(__MODULE__, acc), rest}}
      end

      defp __skir_finish_decode__(extra, rest, acc, count, :keep) do
        case Skir.Wire.Skip.capture_n_values(extra, rest) do
          {:ok, {captured, final_rest}} ->
            unrec = %Skir.Unrecognized{format: :binary, data: captured, array_len: count}
            {:ok, {struct(__MODULE__, Map.put(acc, :__skir_unrecognized__, unrec)), final_rest}}

          {:error, _} = err ->
            err
        end
      end

      defp __skir_finish_decode__(extra, rest, acc, _count, :drop) do
        case Skir.Wire.Skip.skip_n_values(extra, rest) do
          {:ok, final_rest} -> {:ok, {struct(__MODULE__, acc), final_rest}}
          {:error, _} = err -> err
        end
      end
    end
  end

  # ===========================================================================
  # Stage 5: JSON  (to_dense, to_readable, decode_json)
  # ===========================================================================

  # --- to_json (dense + readable) ---

  defp gen_to_json(fields) do
    quote do
      unquote(gen_to_dense_json(fields))
      unquote(gen_to_readable_json(fields))
    end
  end

  # Dense JSON: array of slots, approach (D). Two branches:
  #   * preserved JSON tail -> all recognized slots + tail (no trim)
  #   * normal -> Enum.take(slots, highest_non_default)
  defp gen_to_dense_json(fields) do
    positions = build_position_list(fields)
    v = Macro.var(:v, __MODULE__)

    all_slots_ast =
      Enum.map(positions, fn pos -> dense_slot_ast(pos, v) end)

    quote do
      def __skir_to_dense_json__(
            %__MODULE__{
              __skir_unrecognized__: %Skir.Unrecognized{format: :json, data: tail}
            } = unquote(v)
          )
          when tail != [] do
        slots = unquote(all_slots_ast)
        slots ++ tail
      end

      def __skir_to_dense_json__(%__MODULE__{} = unquote(v)) do
        count = __skir_highest_non_default__(unquote(v))
        slots = unquote(all_slots_ast)
        Enum.take(slots, count)
      end

      def __skir_to_dense_json__({:__lazy_default__, _}), do: []
    end
  end

  defp dense_slot_ast(:removed, _v), do: 0

  defp dense_slot_ast({:field, f}, v) do
    field_access = quote(do: unquote(v).unquote(Macro.var(f.name, nil)))
    Skir.Struct.TypeResolver.to_json_dense_ast(f.type, field_access)
  end

  # Readable JSON: object with only non-default fields, in field order.
  defp gen_to_readable_json(fields) do
    v = Macro.var(:v, __MODULE__)

    # Build a list of {include?, {name, value}} per field; filter at runtime.
    pair_clauses =
      Enum.map(fields, fn f ->
        field_access = quote(do: unquote(v).unquote(Macro.var(f.name, nil)))
        json_value = Skir.Struct.TypeResolver.to_json_readable_ast(f.type, field_access)
        is_default_check = readable_is_default_ast(f.type, field_access)
        name_str = Atom.to_string(f.name)

        quote do
          if unquote(is_default_check) do
            []
          else
            [{unquote(name_str), unquote(json_value)}]
          end
        end
      end)

    pairs_ast =
      Enum.reduce(pair_clauses, [], fn clause, acc ->
        quote(do: unquote(acc) ++ unquote(clause))
      end)

    quote do
      def __skir_to_readable_json__(%__MODULE__{} = unquote(v)) do
        Jason.OrderedObject.new(unquote(pairs_ast))
      end

      def __skir_to_readable_json__({:__lazy_default__, _}) do
        Jason.OrderedObject.new([])
      end
    end
  end

  # is-default check for a field value (used to skip default fields in readable).
  defp readable_is_default_ast(:bool, va), do: quote(do: unquote(va) == false)
  defp readable_is_default_ast(:int32, va), do: quote(do: unquote(va) == 0)
  defp readable_is_default_ast(:int64, va), do: quote(do: unquote(va) == 0)
  defp readable_is_default_ast(:hash64, va), do: quote(do: unquote(va) == 0)

  defp readable_is_default_ast(:float32, va),
    do: quote(do: unquote(va) == +0.0 or unquote(va) == -0.0)

  defp readable_is_default_ast(:float64, va),
    do: quote(do: unquote(va) == +0.0 or unquote(va) == -0.0)

  defp readable_is_default_ast(:string, va), do: quote(do: unquote(va) == "")
  defp readable_is_default_ast(:bytes, va), do: quote(do: unquote(va) == "")

  defp readable_is_default_ast(:timestamp, va),
    do: quote(do: unquote(va) == ~U[1970-01-01 00:00:00.000Z])

  defp readable_is_default_ast({:optional, _}, va), do: quote(do: is_nil(unquote(va)))
  defp readable_is_default_ast({:array, _}, va), do: quote(do: unquote(va) == [])

  defp readable_is_default_ast({:array, _, _}, va) do
    quote do
      unquote(va) == [] or match?(%Skir.KeyedList{items: []}, unquote(va))
    end
  end

  defp readable_is_default_ast(mod, va) when is_atom(mod) do
    quote do
      case unquote(va) do
        {:__lazy_default__, _} ->
          true

        v ->
          if function_exported?(unquote(mod), :__skir_is_default__, 1) do
            unquote(mod).__skir_is_default__(v)
          else
            v == unquote(mod).default()
          end
      end
    end
  end

  # --- decode_json (form dispatch: list | map | 0 | other) ---

  defp gen_decode_json(fields) do
    positions = build_position_list(fields)
    recognized = length(positions)

    # list form: dense array. index -> field decode.
    list_field_clauses =
      for {pos, idx} <- Enum.with_index(positions), match?({:field, _}, pos) do
        {:field, f} = pos
        decode_ast =
          Skir.Struct.TypeResolver.decode_json_ast(
            f.type,
            quote(do: Enum.at(list, unquote(idx))),
            quote(do: path ++ [unquote(f.name)]),
            quote(do: keep)
          )

        {idx, f.name, decode_ast}
      end

    # Build the accumulator map for list form.
    list_puts =
      Enum.reduce(list_field_clauses, quote(do: acc0), fn {idx, name, decode_ast}, acc ->
        quote do
          acc = unquote(acc)

          if unquote(idx) < length_list do
            Map.put(acc, unquote(name), unquote(decode_ast))
          else
            acc
          end
        end
      end)

    # map form: readable object. key string -> field decode.
    map_field_clauses =
      for {:field, f} <- positions do
        name_str = Atom.to_string(f.name)
        decode_ast =
          Skir.Struct.TypeResolver.decode_json_ast(
            f.type,
            quote(do: map_val),
            quote(do: path ++ [unquote(f.name)]),
            quote(do: keep)
          )

        quote do
          case Map.fetch(map, unquote(name_str)) do
            {:ok, map_val} -> Map.put(acc, unquote(f.name), unquote(decode_ast))
            :error -> acc
          end
        end
      end

    map_puts =
      Enum.reduce(map_field_clauses, quote(do: acc0), fn clause, acc ->
        quote do
          acc = unquote(acc)
          unquote(clause)
        end
      end)

    quote do
      def __skir_decode_json__(list, path, keep) when is_list(list) do
        acc0 = __skir_defaults_map__()
        length_list = length(list)
        fields_map = unquote(list_puts)

        fields_map =
          if keep == :keep and length_list > unquote(recognized) do
            tail = Enum.drop(list, unquote(recognized))

            Map.put(fields_map, :__skir_unrecognized__, %Skir.Unrecognized{
              format: :json,
              data: tail,
              array_len: length_list
            })
          else
            fields_map
          end

        struct(__MODULE__, fields_map)
      end

      def __skir_decode_json__(0, _path, _keep) do
        struct(__MODULE__, __skir_defaults_map__())
      end

      def __skir_decode_json__(map, path, keep) when is_map(map) and not is_struct(map) do
        acc0 = __skir_defaults_map__()
        fields_map = unquote(map_puts)
        struct(__MODULE__, fields_map)
      end

      def __skir_decode_json__(other, path, _keep) do
        raise Skir.DecodeError, path: path, expected: :struct, got: other, reason: :type_mismatch
      end
    end
  end
end
