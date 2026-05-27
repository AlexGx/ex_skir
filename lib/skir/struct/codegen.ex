defmodule Skir.Struct.Codegen do
  @moduledoc false
  # Compile-time code generation for Skir structs.
  #
  # Stage 1 — generate two pure check functions alongside the existing
  # runtime-closure architecture (no behavior change yet):
  #
  #   * `__skir_is_default__/1`     — is this value the all-defaults struct?
  #   * `__skir_highest_non_default__/1` — smallest N such that emitting the
  #                                       first N slots is sufficient.
  #
  # These mirror the runtime `Compiler.struct_is_default` and
  # `Compiler.highest_non_default` exactly, but as specialised functions
  # generated at compile time. They will replace those runtime helpers in
  # later stages; for now they exist in parallel and are validated against
  # the runtime path by tests.

  @doc """
  Generates the `__skir_is_default__/1` and `__skir_highest_non_default__/1`
  functions for a struct module. Returns a quoted block to splice into the
  module's body via `__before_compile__`.
  """
  def generate(fields) do
    is_default_ast = gen_is_default(fields)
    highest_ast = gen_highest_non_default(fields)

    quote do
      unquote(is_default_ast)
      unquote(highest_ast)
    end
  end

  # ===========================================================================
  # __skir_is_default__/1
  # ===========================================================================
  #
  # Two heads:
  #   1. struct with __skir_unrecognized__ set → not default (preserved data)
  #   2. struct with all fields at default → true; else fall through to false
  #
  # Primitive fields are matched literally in the pattern. Composite/record
  # fields can't be matched literally (their default needs a runtime check)
  # so they're bound as variables and checked in a guard or `cond` body.

  defp gen_is_default(fields) do
    # Partition fields into "primitive default checks fit in the pattern"
    # vs "needs a runtime call".
    {pattern_fields, runtime_check_fields} =
      Enum.split_with(fields, fn f -> primitive_default_pattern?(f.type) end)

    pattern_pairs =
      Enum.map(pattern_fields, fn f ->
        {f.name, primitive_default_pattern(f.type)}
      end)

    pattern_pairs = [{:__skir_unrecognized__, nil} | pattern_pairs]

    if runtime_check_fields == [] do
      # Pure pattern match — primitives only. The fastest path.
      quote do
        def __skir_is_default__(%__MODULE__{unquote_splicing(pattern_pairs)}), do: true
        def __skir_is_default__(_), do: false
      end
    else
      # Mixed — primitives in pattern, composite/record checked in body.
      # Bind composite fields to variables in the pattern, check via `and`.
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

  # Does this type have a literal pattern that exactly represents its default?
  # Primitives and `nil`/`[]` for optional/array fit; record fields don't
  # (their default is `mod.default()` which needs a runtime call), but the
  # self-recursive sentinel `{:__lazy_default__, __MODULE__}` does.
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
  # Keyed array default is %KeyedList{items: []} — can be matched but
  # plain [] (from default before wrap) can occur. Handle in body.
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

  # Generates a body expression that's true when the variable holds the
  # default value of the given type. Used for fields not in the pattern.
  defp non_pattern_is_default_check({:array, _, _}, var) do
    # Keyed array — default is %KeyedList{items: []} or plain [].
    quote do
      unquote(var) == [] or match?(%Skir.KeyedList{items: []}, unquote(var))
    end
  end

  defp non_pattern_is_default_check(mod, var) when is_atom(mod) do
    # Other-module struct/enum. Default is either the lazy sentinel
    # (unresolved recursive self-ref) or `mod.default()` materialised.
    # Match sentinel literally; otherwise call the module's
    # `__skir_is_default__/1` (or fall back to equality if not yet generated).
    #
    # NOTE: We rely on the referenced module being a Skir struct/enum
    # that implements `__skir_is_default__/1`. If not — falls back to ==.
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
  # __skir_highest_non_default__/1
  # ===========================================================================
  #
  # Returns the smallest N such that emitting slots 0..N-1 is sufficient:
  #   * if __skir_unrecognized__ is set → total_slots (emit everything)
  #   * else: walk fields in descending number order, return (first
  #     non-default field).number + 1
  #   * else: 0 (all fields at default)

  defp gen_highest_non_default(fields) do
    fields_desc = Enum.sort_by(fields, & &1.number, :desc)
    max_field_num = fields |> Enum.map(& &1.number) |> Enum.max(fn -> -1 end)
    total_slots = max_field_num + 1

    # One `cond` clause per field — guard-style `field_var != default`
    # expressed as a runtime check (works for any type, including records).
    cond_clauses = build_cond_clauses(fields_desc)

    if fields == [] do
      quote do
        def __skir_highest_non_default__(_), do: 0
      end
    else
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

  # Builds the AST list of `condition -> value` pairs for a `cond`. The
  # final clause is `true -> 0` so the cond is total.
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

    # Flatten — each `quote do ... -> ... end` is a `[->]` list, we want
    # all clauses concatenated into the cond body.
    Enum.flat_map(field_clauses ++ [fallback], fn ast ->
      case ast do
        {:->, _, _} = single -> [single]
        list when is_list(list) -> list
        other -> [other]
      end
    end)
  end

  # AST for "this field value is NOT the default" for the given type.
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
    # Record field: not default = (not the sentinel) AND (not is_default per mod).
    # We do the runtime call. `function_exported?` check guards against
    # forward-ref oddities at first compile pass.
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
end
