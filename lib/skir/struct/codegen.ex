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
end
