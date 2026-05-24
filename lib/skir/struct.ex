defmodule Skir.Struct do
  @moduledoc """
  DSL for defining Skir structs. See module-level Skir docs for usage.
  """

  alias Skir.Serializer
  alias Skir.TypeAdapter
  alias Skir.DecodeError
  alias Skir.Wire.Skip

  @spec __using__(keyword()) ::
          {:__block__, [], [{:@ | :import | {any(), any(), any()}, [...], [...]}, ...]}
  defmacro __using__(opts) do
    stable_id = Keyword.get(opts, :id)

    quote do
      import Skir.Struct, only: [field: 3, field: 4, removed: 1]

      Module.register_attribute(__MODULE__, :__skir_fields__, accumulate: true)
      Module.register_attribute(__MODULE__, :__skir_removed__, accumulate: true)
      @__skir_stable_id__ unquote(stable_id)
      @before_compile Skir.Struct
    end
  end

  defmacro field(name, type, number, opts \\ []) do
    resolved = Skir.Struct.Resolver.resolve(type, __CALLER__)

    quote do
      @__skir_fields__ %{
        name: unquote(name),
        number: unquote(number),
        type: unquote(Macro.escape(resolved)),
        doc: unquote(Keyword.get(opts, :doc))
      }
    end
  end

  defmacro removed(spec) do
    quote(do: @__skir_removed__(unquote(spec)))
  end

  defmacro __before_compile__(env) do
    fields = env.module |> Module.get_attribute(:__skir_fields__) |> Enum.reverse()
    removed_raw = env.module |> Module.get_attribute(:__skir_removed__) |> Enum.reverse()
    stable_id = Module.get_attribute(env.module, :__skir_stable_id__)
    removed = expand_removed(removed_raw)

    validate_numbering!(env.module, fields, removed)

    field_names = Enum.map(fields, & &1.name)
    enforce = fields |> Enum.reject(&optional?/1) |> Enum.map(& &1.name)
    max_num = max_num(fields, removed)
    positions = build_positions(fields, removed, max_num)
    defaults = defaults_map(fields)

    quote do
      @enforce_keys unquote(enforce)
      # TODO: fix consolidation
      # @derive {Inspect, except: [:__skir_unrecognized__]}
      defstruct unquote(field_names ++ [__skir_unrecognized__: nil])

      # @review: cleanup, was experimental
      # @behaviour Skir.Struct.Behaviour

      @type t :: %__MODULE__{unquote_splicing(Skir.Struct.TypeGen.field_specs_ast(fields))}

      @__skir_stable_id__ unquote(stable_id)

      # Defaults are stored as-is (with {:__lazy_default__, Module} sentinels
      # for nested types) because the nested modules may not exist yet at
      # compile time. We resolve the sentinels on first call and cache.
      @__skir_defaults_raw__ unquote(Macro.escape(defaults))

      @__skir_fields_meta__ unquote(Macro.escape(fields))

      def __skir_defaults__ do
        key = {__MODULE__, :__skir_defaults__}

        case :persistent_term.get(key, :__not_built__) do
          :__not_built__ ->
            resolved =
              Map.new(@__skir_defaults_raw__, fn
                {k, {:__lazy_default__, mod}} when mod == __MODULE__ ->
                  # Recursive self-reference: leave the sentinel unresolved.
                  # A recursive type has no finite eager default; materializing
                  # it would loop forever. Treated as the field's default.
                  {k, {:__lazy_default__, mod}}

                {k, {:__lazy_default__, mod}} ->
                  {k, mod.default()}

                kv ->
                  kv
              end)

            :persistent_term.put(key, resolved)
            resolved

          resolved ->
            resolved
        end
      end

      # Constructors

      # @review: deprecate in flavor of elixir native struct
      @spec new(unquote(Skir.Struct.TypeGen.new_input_map_ast(fields))) :: t()
      def new(fields) when is_map(fields) do
        struct!(__MODULE__, Skir.Struct.wrap_keyed_fields(fields, @__skir_fields_meta__))
      end

      @spec partial(unquote(Skir.Struct.TypeGen.partial_input_map_ast(fields))) :: t()
      def partial(fields \\ %{}) when is_map(fields) do
        wrapped = Skir.Struct.wrap_keyed_fields(fields, @__skir_fields_meta__)
        struct(__MODULE__, Map.merge(__skir_defaults__(), wrapped))
      end

      # @review: gleam/rust idiomatic, not elixir
      @spec default() :: t()
      def default, do: partial(%{})

      # @review: also not elixir idiomatic
      @spec merge(t(), map()) :: t()
      def merge(%__MODULE__{} = base, overrides) when is_map(overrides),
        do: struct(base, overrides)

      # Runtime serializer — built lazily and cached via :persistent_term.
      # Module attributes can't hold closures, so we can't embed it directly;
      # :persistent_term gives O(1) read after the first build and is the
      # idiomatic BEAM way to cache "build once, read many" data.
      @__skir_serializer_args__ {
        unquote(Macro.escape(fields)),
        unquote(Macro.escape(positions)),
        unquote(Macro.escape(defaults))
      }

      def __skir_serializer__ do
        key = {__MODULE__, :__skir_serializer__}

        case :persistent_term.get(key, :__not_built__) do
          :__not_built__ ->
            {fields, positions, defaults} = @__skir_serializer_args__

            serializer =
              Skir.Struct.Compiler.build_serializer(__MODULE__, fields, positions, defaults)

            :persistent_term.put(key, serializer)
            serializer

          serializer ->
            serializer
        end
      end

      # User-facing API
      @spec to_binary(t()) :: binary()
      def to_binary(value), do: Skir.Serializer.encode_binary(__skir_serializer__(), value)

      @spec to_json(t()) :: binary()
      @spec to_json(t(), :dense | :readable) :: binary()
      def to_json(value, flavor \\ :dense),
        do: Skir.Serializer.encode_json(__skir_serializer__(), value, flavor)

      @spec from_binary(binary()) :: {:ok, t()} | {:error, Skir.DecodeError.t()}
      @spec from_binary(binary(), keyword()) :: {:ok, t()} | {:error, Skir.DecodeError.t()}
      def from_binary(bytes, opts \\ []),
        do: Skir.Serializer.decode_binary(__skir_serializer__(), bytes, opts)

      @spec from_binary!(binary()) :: t()
      @spec from_binary!(binary(), keyword()) :: t()
      def from_binary!(bytes, opts \\ []),
        do: Skir.Serializer.decode_binary!(__skir_serializer__(), bytes, opts)

      @spec from_json(binary()) :: {:ok, t()} | {:error, Skir.DecodeError.t()}
      def from_json(bin), do: Skir.Serializer.decode_json(__skir_serializer__(), bin)

      @spec from_json!(binary()) :: t()
      def from_json!(bin), do: Skir.Serializer.decode_json!(__skir_serializer__(), bin)

      # Reflection

      @spec __skir_schema__() :: map()
      def __skir_schema__ do
        %{
          module: __MODULE__,
          stable_id: @__skir_stable_id__,
          fields: unquote(Macro.escape(fields)),
          removed: unquote(Macro.escape(removed))
        }
      end
    end
  end

  # --- helpers ---

  defp expand_removed(raw) do
    Enum.flat_map(raw, fn
      n when is_integer(n) -> [n]
      %Range{} = r -> Enum.to_list(r)
      l when is_list(l) -> l
    end)
  end

  defp validate_numbering!(mod, fields, removed) do
    used = Enum.map(fields, & &1.number) ++ removed
    dups = used -- Enum.uniq(used)

    if dups != [] do
      raise CompileError,
        description: "#{inspect(mod)}: duplicate field numbers #{inspect(dups)}"
    end

    sorted = Enum.sort(used)

    cond do
      sorted == [] ->
        :ok

      hd(sorted) != 0 ->
        raise CompileError, description: "#{inspect(mod)}: field numbers must start at 0"

      true ->
        expected = Enum.to_list(0..List.last(sorted))
        missing = expected -- sorted

        if missing != [] do
          raise CompileError,
            description: "#{inspect(mod)}: gaps #{inspect(missing)}, use `removed N`"
        end
    end
  end

  defp optional?(%{type: {:optional, _}}), do: true
  defp optional?(%{type: {:array, _}}), do: true
  defp optional?(%{type: {:array, _, _}}), do: true
  defp optional?(_), do: false

  defp max_num([], []), do: -1

  defp max_num(fields, removed) do
    fmax = fields |> Enum.map(& &1.number) |> Enum.max(fn -> -1 end)
    rmax = Enum.max(removed, fn -> -1 end)
    max(fmax, rmax)
  end

  defp build_positions(_fields, _removed, -1), do: []

  defp build_positions(fields, removed, max) do
    by_num = Map.new(fields, &{&1.number, &1})

    for i <- 0..max//1 do
      cond do
        Map.has_key?(by_num, i) -> {:field, Map.fetch!(by_num, i)}
        i in removed -> :removed
      end
    end
  end

  defp defaults_map(fields) do
    Map.new(fields, fn f -> {f.name, default_for(f.type)} end)
  end

  def default_for(:bool), do: false
  def default_for(:int32), do: 0
  def default_for(:int64), do: 0
  def default_for(:hash64), do: 0
  def default_for(:float32), do: 0.0
  def default_for(:float64), do: 0.0
  def default_for(:string), do: ""
  def default_for(:bytes), do: ""
  def default_for(:timestamp), do: ~U[1970-01-01 00:00:00.000Z]
  def default_for({:optional, _}), do: nil
  def default_for({:array, _}), do: []

  def default_for({:array, _, opts}) when is_list(opts) do
    case Keyword.get(opts, :key) do
      nil -> []
      key_field -> Skir.KeyedList.empty(key_field)
    end
  end

  def default_for(mod) when is_atom(mod), do: {:__lazy_default__, mod}

  @doc """
  For each keyed-list field in `fields_meta`, if the user passed a plain
  list, wrap it in `%Skir.KeyedList{}`. If they passed a `%KeyedList{}`
  already, leave it alone.

  Used by generated `new/1` and `partial/1`.
  """
  def wrap_keyed_fields(input, fields_meta) when is_map(input) and is_list(fields_meta) do
    Enum.reduce(fields_meta, input, fn f, acc ->
      case f.type do
        {:array, _inner, opts} when is_list(opts) ->
          case Keyword.get(opts, :key) do
            nil ->
              acc

            key_field ->
              case Map.fetch(acc, f.name) do
                {:ok, %Skir.KeyedList{}} ->
                  acc

                {:ok, list} when is_list(list) ->
                  Map.put(acc, f.name, Skir.KeyedList.new(list, key_field))

                {:ok, _other} ->
                  acc

                :error ->
                  acc
              end
          end

        _ ->
          acc
      end
    end)
  end
end

defmodule Skir.Struct.Resolver do
  @moduledoc false

  # Walk a type AST, resolving aliases.
  def resolve({:__aliases__, _, _} = ast, caller), do: Macro.expand(ast, caller)

  def resolve({:{}, _, parts}, caller),
    do: List.to_tuple(Enum.map(parts, &resolve(&1, caller)))

  def resolve({a, b}, caller), do: {resolve(a, caller), resolve(b, caller)}
  def resolve(list, caller) when is_list(list), do: Enum.map(list, &resolve(&1, caller))
  def resolve(other, _), do: other
end

defmodule Skir.Struct.Compiler do
  @moduledoc false
  # Build the runtime serializer for a struct. Heavy prep work happens once
  # in build_serializer; closures capture the prepared state.

  alias Skir.Serializer
  alias Skir.TypeAdapter
  alias Skir.DecodeError
  alias Skir.Wire.Skip

  def build_serializer(module, fields, positions, defaults) do
    # Resolve nested module defaults lazily.
    defaults =
      Map.new(defaults, fn
        {k, {:__lazy_default__, mod}} when mod == module ->
          {k, {:__lazy_default__, mod}}

        {k, {:__lazy_default__, mod}} ->
          {k, mod.default()}

        kv ->
          kv
      end)

    # Resolve each field's TypeAdapter once and cache on the field meta.
    # Avoids repeated mod.__skir_serializer__() lookups on the hot path.
    field_adapters =
      Enum.map(fields, fn f ->
        Map.put(f, :adapter, field_adapter_for(f.type, module))
      end)

    # Convert positions list to a tuple for O(1) random access via elem/2.
    positions_tuple = List.to_tuple(positions)

    # Map of field number -> field meta (resolved adapter included).
    # Built once, captured by closures.
    field_by_num = Map.new(field_adapters, &{&1.number, &1})

    # Pre-sort by descending number for highest_non_default — used every encode.
    fields_desc = Enum.sort_by(field_adapters, & &1.number, :desc)

    ta =
      build_type_adapter(
        module,
        field_adapters,
        fields_desc,
        field_by_num,
        positions_tuple,
        defaults
      )

    %Serializer{
      type_adapter: ta,
      module: module,
      name: module |> Module.split() |> List.last(),
      qualified_name: inspect(module)
    }
  end

  def build_type_adapter(
        module,
        field_adapters,
        fields_desc,
        field_by_num,
        positions_tuple,
        defaults
      ) do
    %TypeAdapter{
      is_default: fn
        # A recursive field's default is the unresolved lazy sentinel; it is
        # always "default" (an empty recursive struct).
        {:__lazy_default__, _mod} -> true
        v -> struct_is_default(v, field_adapters, defaults)
      end,
      to_json: fn
        # Sentinel = empty struct: [] dense, {} readable.
        {:__lazy_default__, _mod}, :dense ->
          []

        {:__lazy_default__, _mod}, :readable ->
          Jason.OrderedObject.new([])

        v, flavor ->
          struct_to_json(v, field_adapters, fields_desc, field_by_num, positions_tuple, flavor)
      end,
      decode_json: fn term, path, keep ->
        struct_decode_json(
          term,
          module,
          field_adapters,
          field_by_num,
          positions_tuple,
          defaults,
          path,
          keep
        )
      end,
      encode_binary: fn
        # Sentinel = empty struct: 0xF6 (zero slots).
        {:__lazy_default__, _mod}, acc ->
          [acc, <<0xF6>>]

        v, acc ->
          struct_encode_binary(v, acc, fields_desc, field_by_num, positions_tuple)
      end,
      decode_binary: fn bits, keep ->
        struct_decode_binary(bits, module, field_by_num, positions_tuple, defaults, keep)
      end
    }
  end

  # --- type adapter for a field's type ---

  def type_adapter_for(:bool), do: Serializer.Builtin.bool()
  def type_adapter_for(:int32), do: Serializer.Builtin.int32()
  def type_adapter_for(:int64), do: Serializer.Builtin.int64()
  def type_adapter_for(:hash64), do: Serializer.Builtin.hash64()
  def type_adapter_for(:float32), do: Serializer.Builtin.float32()
  def type_adapter_for(:float64), do: Serializer.Builtin.float64()
  def type_adapter_for(:string), do: Serializer.Builtin.string()
  def type_adapter_for(:bytes), do: Serializer.Builtin.bytes()
  def type_adapter_for(:timestamp), do: Serializer.Builtin.timestamp()

  def type_adapter_for({:optional, inner}),
    do: Serializer.Builtin.optional(type_adapter_for(inner))

  def type_adapter_for({:array, inner}),
    do: Serializer.Builtin.list(type_adapter_for(inner))

  def type_adapter_for({:array, inner, opts}) when is_list(opts) do
    case Keyword.get(opts, :key) do
      nil -> Serializer.Builtin.list(type_adapter_for(inner))
      key_field -> Serializer.Builtin.keyed_list(type_adapter_for(inner), key_field)
    end
  end

  def type_adapter_for(mod) when is_atom(mod),
    do: mod.__skir_serializer__().type_adapter

  #
  # Resolve a field's TypeAdapter. For a direct self-reference (recursive
  # field whose type is the struct being built), return a LAZY adapter that
  # resolves the serializer on first use — building it eagerly here would
  # recurse forever (gleam's FieldSerializer.Lazy).
  defp field_adapter_for(field_type, module) do
    if recursive_self_ref?(field_type, module) do
      lazy_type_adapter(module)
    else
      type_adapter_for(field_type)
    end
  end

  # Direct self-reference: the field's type is the module itself, or an
  # optional/array wrapping it.
  defp recursive_self_ref?(mod, module) when is_atom(mod), do: mod == module
  defp recursive_self_ref?({:optional, inner}, module), do: recursive_self_ref?(inner, module)
  defp recursive_self_ref?({:array, inner}, module), do: recursive_self_ref?(inner, module)
  defp recursive_self_ref?({:array, inner, _opts}, module), do: recursive_self_ref?(inner, module)
  defp recursive_self_ref?(_, _), do: false

  # Lazy adapter: each closure resolves mod.__skir_serializer__() at call
  # time. By the time a value is encoded/decoded the serializer is fully
  # built and cached, so this resolves once and breaks the build-time cycle.
  defp lazy_type_adapter(mod) do
    %TypeAdapter{
      is_default: fn v -> mod.__skir_serializer__().type_adapter.is_default.(v) end,
      to_json: fn v, flavor -> mod.__skir_serializer__().type_adapter.to_json.(v, flavor) end,
      decode_json: fn term, path, keep ->
        mod.__skir_serializer__().type_adapter.decode_json.(term, path, keep)
      end,
      encode_binary: fn v, acc ->
        mod.__skir_serializer__().type_adapter.encode_binary.(v, acc)
      end,
      decode_binary: fn bits, keep ->
        mod.__skir_serializer__().type_adapter.decode_binary.(bits, keep)
      end
    }
  end

  # --- is_default ---

  defp struct_is_default(%_{__skir_unrecognized__: u}, _, _) when not is_nil(u), do: false

  defp struct_is_default(value, field_adapters, defaults) do
    Enum.all?(field_adapters, fn f ->
      v = Map.get(value, f.name)

      case f.type do
        t
        when is_atom(t) and
               t in [
                 :bool,
                 :int32,
                 :int64,
                 :hash64,
                 :float32,
                 :float64,
                 :string,
                 :bytes,
                 :timestamp
               ] ->
          v == Map.fetch!(defaults, f.name)

        {:optional, _} ->
          v == nil

        {:array, _} ->
          v == []

        {:array, _, _} ->
          v == []

        _other ->
          f.adapter.is_default.(v)
      end
    end)
  end

  # --- to_json ---

  defp struct_to_json(value, _field_adapters, fields_desc, field_by_num, positions_tuple, :dense) do
    unrec = Map.get(value, :__skir_unrecognized__)

    {count, tail} =
      case unrec do
        %Skir.Unrecognized{format: :json, data: tail} when tail != [] ->
          # Preserved unrecognized JSON tail: emit ALL recognized slots
          # (no trailing-default trimming, or indices would shift) + the tail.
          {tuple_size(positions_tuple), tail}

        _ ->
          {highest_non_default(value, fields_desc), []}
      end

    slots =
      for i <- 0..(count - 1)//1 do
        case elem(positions_tuple, i) do
          :removed ->
            0

          {:field, _} ->
            f = Map.fetch!(field_by_num, i)
            v = Map.get(value, f.name)

            try do
              f.adapter.to_json.(v, :dense)
            rescue
              e in Skir.EncodeError ->
                reraise %{e | path: [f.name | e.path]}, __STACKTRACE__
            end
        end
      end

    slots ++ tail
  end

  defp struct_to_json(
         value,
         field_adapters,
         _fields_desc,
         _field_by_num,
         _positions_tuple,
         :readable
       ) do
    pairs =
      for f <- field_adapters,
          v = Map.get(value, f.name),
          not f.adapter.is_default.(v) do
        try do
          {Atom.to_string(f.name), f.adapter.to_json.(v, :readable)}
        rescue
          e in Skir.EncodeError ->
            reraise %{e | path: [f.name | e.path]}, __STACKTRACE__
        end
      end

    Jason.OrderedObject.new(pairs)
  end

  defp highest_non_default(value, fields_desc) do
    Enum.find_value(fields_desc, 0, fn f ->
      v = Map.get(value, f.name)
      if f.adapter.is_default.(v), do: nil, else: f.number + 1
    end)
  end

  # --- decode_json ---

  defp struct_decode_json(
         list,
         module,
         _field_adapters,
         field_by_num,
         positions_tuple,
         defaults,
         path,
         keep
       )
       when is_list(list) do
    recognized = tuple_size(positions_tuple)

    fields_map =
      list
      |> Enum.with_index()
      |> Enum.reduce(defaults, fn {v, i}, acc ->
        case Map.get(field_by_num, i) do
          nil ->
            acc

          f ->
            decoded =
              try do
                f.adapter.decode_json.(v, path ++ [f.name], keep)
              rescue
                e in DecodeError -> reraise DecodeError.prepend(e, f.name), __STACKTRACE__
              end

            Map.put(acc, f.name, decoded)
        end
      end)

    fields_map =
      if keep == :keep and length(list) > recognized do
        tail = Enum.drop(list, recognized)

        Map.put(fields_map, :__skir_unrecognized__, %Skir.Unrecognized{
          format: :json,
          data: tail,
          array_len: length(list)
        })
      else
        fields_map
      end

    struct(module, fields_map)
  end

  defp struct_decode_json(
         0,
         module,
         _field_adapters,
         _field_by_num,
         _positions_tuple,
         defaults,
         _path,
         _keep
       ) do
    struct(module, defaults)
  end

  defp struct_decode_json(
         map,
         module,
         field_adapters,
         _field_by_num,
         _positions_tuple,
         defaults,
         path,
         keep
       )
       when is_map(map) and not is_struct(map) do
    field_by_name = Map.new(field_adapters, &{Atom.to_string(&1.name), &1})

    fields_map =
      Enum.reduce(map, defaults, fn {k, v}, acc ->
        case Map.get(field_by_name, k) do
          nil ->
            acc

          f ->
            decoded =
              try do
                f.adapter.decode_json.(v, path ++ [f.name], keep)
              rescue
                e in DecodeError -> reraise DecodeError.prepend(e, f.name), __STACKTRACE__
              end

            Map.put(acc, f.name, decoded)
        end
      end)

    struct(module, fields_map)
  end

  defp struct_decode_json(other, _module, _, _, _, _, path, _keep) do
    raise DecodeError, path: path, expected: :struct, got: other, reason: :type_mismatch
  end

  # --- encode_binary ---

  defp struct_encode_binary(value, acc, fields_desc, field_by_num, positions_tuple) do
    case Map.get(value, :__skir_unrecognized__) do
      %Skir.Unrecognized{format: :binary, data: extra_bytes, array_len: total} ->
        encode_with_preserved(value, acc, field_by_num, positions_tuple, total, extra_bytes)

      _ ->
        encode_normal(value, acc, fields_desc, field_by_num, positions_tuple)
    end
  end

  defp encode_normal(value, acc, fields_desc, field_by_num, positions_tuple) do
    count = highest_non_default(value, fields_desc)
    header = Skir.Wire.Struct.encode_slot_count(count)
    acc2 = [acc, header]

    Enum.reduce(0..(count - 1)//1, acc2, fn i, a ->
      case elem(positions_tuple, i) do
        :removed ->
          [a, <<0x00>>]

        {:field, _} ->
          f = Map.fetch!(field_by_num, i)
          v = Map.get(value, f.name)

          try do
            f.adapter.encode_binary.(v, a)
          rescue
            e in Skir.EncodeError ->
              reraise %{e | path: [f.name | e.path]}, __STACKTRACE__
          end
      end
    end)
  end

  defp encode_with_preserved(value, acc, field_by_num, positions_tuple, total_count, extra_bytes) do
    recognized_count = tuple_size(positions_tuple)
    header = Skir.Wire.Struct.encode_slot_count(total_count)
    acc2 = [acc, header]

    acc3 =
      Enum.reduce(0..(recognized_count - 1)//1, acc2, fn i, a ->
        case elem(positions_tuple, i) do
          :removed ->
            [a, <<0x00>>]

          {:field, _} ->
            f = Map.fetch!(field_by_num, i)
            v = Map.get(value, f.name)

            try do
              f.adapter.encode_binary.(v, a)
            rescue
              e in Skir.EncodeError ->
                reraise %{e | path: [f.name | e.path]}, __STACKTRACE__
            end
        end
      end)

    [acc3, extra_bytes]
  end

  # --- decode_binary ---

  defp struct_decode_binary(bits, module, field_by_num, positions_tuple, defaults, keep) do
    case Skir.Wire.Struct.decode_slot_count(bits) do
      {:ok, {count, rest}} ->
        recognized_count = tuple_size(positions_tuple)
        slots_to_fill = min(count, recognized_count)

        result =
          Enum.reduce_while(0..(slots_to_fill - 1)//1, {defaults, rest}, fn i, {acc, b} ->
            case elem(positions_tuple, i) do
              :removed ->
                case Skip.skip_value(b) do
                  {:ok, r2} -> {:cont, {acc, r2}}
                  err -> {:halt, err}
                end

              {:field, _} ->
                f = Map.fetch!(field_by_num, i)

                case f.adapter.decode_binary.(b, keep) do
                  {:ok, {v, r2}} -> {:cont, {Map.put(acc, f.name, v), r2}}
                  err -> {:halt, err}
                end
            end
          end)

        case result do
          {:error, _} = err ->
            err

          {acc_map, after_recognized} ->
            extra = count - slots_to_fill

            cond do
              extra == 0 ->
                {:ok, {struct(module, acc_map), after_recognized}}

              keep == :keep ->
                case Skip.capture_n_values(extra, after_recognized) do
                  {:ok, {captured, final_rest}} ->
                    unrec = %Skir.Unrecognized{
                      format: :binary,
                      data: captured,
                      array_len: count
                    }

                    value = struct(module, Map.put(acc_map, :__skir_unrecognized__, unrec))
                    {:ok, {value, final_rest}}

                  err ->
                    err
                end

              true ->
                case Skip.skip_n_values(extra, after_recognized) do
                  {:ok, final_rest} -> {:ok, {struct(module, acc_map), final_rest}}
                  err -> err
                end
            end
        end

      {:error, _} = err ->
        err
    end
  end
end
