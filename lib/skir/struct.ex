defmodule Skir.Struct do
  @moduledoc """
  DSL for defining Skir structs. See module-level Skir docs for usage.
  """

  alias Skir.Serializer

  defmacro __using__(opts) do
    stable_id = Keyword.get(opts, :id)
    module_path = Keyword.get(opts, :module_path, "")
    qualified_name = Keyword.get(opts, :qualified_name)
    doc = Keyword.get(opts, :doc, "")

    quote do
      import Skir.Struct, only: [field: 3, field: 4, removed: 1]

      Module.register_attribute(__MODULE__, :__skir_fields__, accumulate: true)
      Module.register_attribute(__MODULE__, :__skir_removed__, accumulate: true)
      @__skir_stable_id__ unquote(stable_id)
      @__skir_module_path__ unquote(module_path)
      @__skir_qualified_name__ unquote(qualified_name)
      @__skir_doc__ unquote(doc)
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
    # max_num = max_num(fields, removed)
    #  positions = build_positions(fields, removed, max_num)
    # defaults = defaults_map(fields)

    quote do
      @enforce_keys unquote(enforce)
      # TODO: fix consolidation
      # @derive {Inspect, except: [:__skir_unrecognized__]}
      defstruct unquote(field_names ++ [__skir_unrecognized__: nil])

      # @review: cleanup, was experimental
      # @behaviour Skir.Struct.Behaviour

      @type t :: %__MODULE__{unquote_splicing(Skir.Struct.TypeGen.field_specs_ast(fields))}

      @__skir_stable_id__ unquote(stable_id)

      @__skir_fields_meta__ unquote(Macro.escape(fields))

      unquote(
        Skir.Struct.Codegen.generate(
          fields,
          %{
            module_path: Module.get_attribute(env.module, :__skir_module_path__) || "",
            qualified_name:
              Module.get_attribute(env.module, :__skir_qualified_name__) ||
                env.module |> Module.split() |> List.last(),
            doc: Module.get_attribute(env.module, :__skir_doc__) || "",
            removed: removed
          }
        )
      )

      # Constructors

      # @review: deprecate in flavor of elixir native struct
      @spec new(unquote(Skir.Struct.TypeGen.new_input_map_ast(fields))) :: t()
      def new(fields) when is_map(fields) do
        struct!(__MODULE__, Skir.Struct.wrap_keyed_fields(fields, @__skir_fields_meta__))
      end

      @spec partial(unquote(Skir.Struct.TypeGen.partial_input_map_ast(fields))) :: t()
      def partial(fields \\ %{}) when is_map(fields) do
        wrapped = Skir.Struct.wrap_keyed_fields(fields, @__skir_fields_meta__)
        struct(__MODULE__, Map.merge(__skir_defaults_map__(), wrapped))
      end

      # @review: also not elixir idiomatic
      @spec merge(t(), map()) :: t()
      def merge(%__MODULE__{} = base, overrides) when is_map(overrides),
        do: struct(base, overrides)

      # User-facing API
      @spec to_binary(t()) :: binary()
      # def to_binary(value), do: Skir.Serializer.encode_binary(__skir_serializer__(), value)
      def to_binary(value), do: IO.iodata_to_binary(__skir_encode_binary__(value, ["skir"]))

      @spec to_json(t()) :: binary()
      @spec to_json(t(), :dense | :readable) :: binary()
      def to_json(value, flavor \\ :dense)

      def to_json(value, :dense) do
        __skir_to_dense_json__(value) |> JSON.encode_to_iodata!() |> IO.iodata_to_binary()
      end

      def to_json(value, :readable) do
        __skir_to_readable_json__(value) |> Jason.encode!(pretty: true)
      end

      @spec from_binary(binary()) :: {:ok, t()} | {:error, Skir.DecodeError.t()}
      @spec from_binary(binary(), keyword()) :: {:ok, t()} | {:error, Skir.DecodeError.t()}
      def from_binary(bytes, opts \\ []) do
        {:ok, from_binary!(bytes, opts)}
      rescue
        e in Skir.DecodeError -> {:error, e}
      end

      @spec from_binary!(binary()) :: t()
      @spec from_binary!(binary(), keyword()) :: t()
      def from_binary!(bytes, opts \\ []) do
        keep = if Keyword.get(opts, :keep, false), do: :keep, else: :drop

        case bytes do
          <<"skir", body::binary>> ->
            case __skir_decode_binary__(body, keep) do
              {:ok, {value, _rest}} ->
                value

              {:error, reason} ->
                raise Skir.DecodeError,
                  path: [],
                  expected: :binary,
                  got: reason,
                  reason: :malformed_input
            end

          _ ->
            # No magic prefix — try JSON (still via old serializer path until Stage 5).
            try do
              from_json!(bytes)
            rescue
              _ ->
                raise Skir.DecodeError,
                  path: [],
                  expected: :binary,
                  got: bytes,
                  reason: :malformed_input
            end
        end
      end

      # @spec from_json(binary()) :: {:ok, t()} | {:error, Skir.DecodeError.t()}
      # def from_json(bin), do: Skir.Serializer.decode_json(__skir_serializer__(), bin)

      # @spec from_json!(binary()) :: t()
      # def from_json!(bin), do: Skir.Serializer.decode_json!(__skir_serializer__(), bin)

      def from_json(bin), do: from_json(bin, [])

      def from_json(bin, opts) do
        {:ok, from_json!(bin, opts)}
      rescue
        e in Skir.DecodeError -> {:error, e}
      end

      def from_json!(bin, opts \\ []) when is_binary(bin) do
        keep = if Keyword.get(opts, :keep, false), do: :keep, else: :drop
        term = JSON.decode!(bin)
        __skir_decode_json__(term, [], keep)
      end

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

  def type_adapter_for(mod) when is_atom(mod) do
    %Skir.TypeAdapter{
      is_default: &mod.__skir_is_default__/1,
      encode_binary: fn v, acc -> mod.__skir_encode_binary__(v, acc) end,
      decode_binary: fn bits, keep -> mod.__skir_decode_binary__(bits, keep) end,
      to_json: fn
        v, :dense -> mod.__skir_to_dense_json__(v)
        v, :readable -> mod.__skir_to_readable_json__(v)
      end,
      decode_json: fn term, path, keep -> mod.__skir_decode_json__(term, path, keep) end,
      type_descriptor: fn -> mod.__skir_type_descriptor__() end
    }
  end
end
