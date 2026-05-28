defmodule Skir.Enum do
  @moduledoc """
  DSL for defining Skir enums (sum types).

  ## Runtime representation

    * **Constant variants** → bare atoms: `:free`, `:premium`, `:unknown`
    * **Wrapper variants** → tagged tuples: `{:trial, %Trial{}}`

  The implicit `:unknown` variant exists in every enum (number 0).
  Pattern matching is natural and exhaustive-checkable:

      case status do
        :free                          -> ...
        :premium                       -> ...
        {:trial, %Trial{start_time: t}} -> ...
        :unknown                       -> ...
      end

  ## Forward compatibility

  When decoding, unknown variant numbers always become `:unknown` rather
  than raising. This matches the Skir spec — `:unknown` is the
  forward-compatibility escape hatch and must always be a valid output.
  """

  alias Skir.TypeAdapter
  alias Skir.Serializer
  alias Skir.Wire.Number
  alias Skir.Wire.Skip

  defmacro __using__(opts) do
    stable_id = Keyword.get(opts, :id)
    module_path = Keyword.get(opts, :module_path, "")
    qualified_name = Keyword.get(opts, :qualified_name)
    doc = Keyword.get(opts, :doc, "")

    quote do
      import Skir.Enum, only: [variant: 2, variant: 3, removed: 1]
      Module.register_attribute(__MODULE__, :__skir_variants__, accumulate: true)
      Module.register_attribute(__MODULE__, :__skir_removed__, accumulate: true)
      @__skir_stable_id__ unquote(stable_id)
      @__skir_module_path__ unquote(module_path)
      @__skir_qualified_name__ unquote(qualified_name)
      @__skir_doc__ unquote(doc)
      @before_compile Skir.Enum
    end
  end

  @doc "Declare a constant variant: `variant :free, 1`."
  defmacro variant(name, number) do
    quote do
      @__skir_variants__ %{
        name: unquote(name),
        number: unquote(number),
        kind: :constant,
        wraps: nil,
        doc: ""
      }
    end
  end

  @doc """
  Declare a wrapper variant: `variant :trial, 2, wraps: SkirOut.Trial`.
  The `wraps:` value can be a primitive (`:string`, `:int32`, etc.) or
  another schema module.
  """
  defmacro variant(name, number, opts) do
    wraps_ast = Keyword.get(opts, :wraps)
    doc = Keyword.get(opts, :doc, "")

    resolved =
      case wraps_ast do
        nil -> nil
        ast -> Skir.Struct.Resolver.resolve(ast, __CALLER__)
      end

    kind = if resolved, do: :wrapper, else: :constant

    quote do
      @__skir_variants__ %{
        name: unquote(name),
        number: unquote(number),
        kind: unquote(kind),
        wraps: unquote(Macro.escape(resolved)),
        doc: unquote(doc)
      }
    end
  end

  @doc """
  Mark a variant number (or range/list of numbers) as removed.

      removed 4
      removed 2..3
  """
  defmacro removed(spec) do
    quote(do: @__skir_removed__(unquote(spec)))
  end

  defmacro __before_compile__(env) do
    variants = env.module |> Module.get_attribute(:__skir_variants__) |> Enum.reverse()
    removed_raw = env.module |> Module.get_attribute(:__skir_removed__) |> Enum.reverse()
    stable_id = Module.get_attribute(env.module, :__skir_stable_id__)

    removed =
      Enum.flat_map(removed_raw, fn
        n when is_integer(n) -> [n]
        %Range{} = r -> Enum.to_list(r)
        l when is_list(l) -> l
      end)

    validate_numbering!(env.module, variants, removed)

    quote do
      @type t :: unquote(Skir.Enum.TypeGen.union_ast(variants))

      # Stored under non-accumulating names so they don't conflict with the
      # accumulator attributes used by the `variant`/`removed` macros above.
      @__skir_variants_resolved__ unquote(Macro.escape(variants))
      @__skir_removed_resolved__ unquote(Macro.escape(removed))
      @__skir_stable_id__ unquote(stable_id)

      unquote(
        Skir.Enum.Codegen.generate(
          variants,
          removed,
          %{
            module_path: Module.get_attribute(env.module, :__skir_module_path__) || "",
            qualified_name:
              Module.get_attribute(env.module, :__skir_qualified_name__) ||
                env.module |> Module.split() |> List.last(),
            doc: Module.get_attribute(env.module, :__skir_doc__) || ""
          }
        )
      )

      def __skir_schema__ do
        %{
          module: __MODULE__,
          variants: @__skir_variants_resolved__,
          removed: @__skir_removed_resolved__,
          stable_id: @__skir_stable_id__
        }
      end

      # closures can't live in a module attribute, so we cache the built
      # serializer in :persistent_term on first call.
      @__skir_serializer_args__ {
        @__skir_variants_resolved__,
        @__skir_removed_resolved__,
        %{
          module_path: @__skir_module_path__,
          qualified_name: @__skir_qualified_name__ || __MODULE__ |> Module.split() |> List.last(),
          doc: @__skir_doc__ || ""
        }
      }

      def __skir_serializer__ do
        key = {__MODULE__, :__skir_serializer__}

        case :persistent_term.get(key, :__not_built__) do
          :__not_built__ ->
            {variants, removed, meta} = @__skir_serializer_args__
            serializer = Skir.Enum.Compiler.build_serializer(__MODULE__, variants, removed, meta)
            :persistent_term.put(key, serializer)
            serializer

          serializer ->
            serializer
        end
      end

      # User-facing API

      @doc """
      Encode the enum value to Skir binary format. The result is prefixed
      with the 4-byte `"skir"` magic so receivers can dispatch between
      binary and JSON without out-of-band metadata.
      """
      def to_binary(value), do: IO.iodata_to_binary(__skir_encode_binary__(value, ["skir"]))

      @doc """
      Encode the enum value to JSON. `flavor` controls the format:

        * `:dense` — variant number (or `[number, payload]` for wrappers).
        * `:readable` — variant name (or `%{"kind" => name, "value" => ...}`).
      """
      def to_json(value, flavor \\ :dense)

      def to_json(value, :dense),
        do: __skir_to_dense_json__(value) |> JSON.encode_to_iodata!() |> IO.iodata_to_binary()

      def to_json(value, :readable),
        do: __skir_to_readable_json__(value) |> Jason.encode!(pretty: true)

      @doc """
      Decode bytes into an enum value. Dispatches by content:

        * Bytes starting with `"skir"` are decoded as Skir binary.
        * Other bytes are tried as JSON.

      Unknown variant numbers always decode to `:unknown`, never raise.

      ## Options

        * `:keep` — when `true`, preserves unknown variants as
          `{:unknown, %Skir.Unrecognized{}}` so re-encoding produces
          byte-identical output. Default: `false`.
      """
      def from_binary(bytes, opts \\ []) do
        {:ok, from_binary!(bytes, opts)}
      rescue
        e in Skir.DecodeError -> {:error, e}
      end

      @doc "Like `from_binary/2` but raises `Skir.DecodeError` on failure."
      @spec from_binary!(binary()) :: t()
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

      @doc "Decode a JSON string into an enum value."
      @spec from_json(binary()) :: {:ok, t()} | {:error, Skir.DecodeError.t()}
      def from_json(bin), do: from_json(bin, [])

      def from_json(bin, opts) do
        {:ok, from_json!(bin, opts)}
      rescue
        e in Skir.DecodeError -> {:error, e}
      end

      @doc "Like `from_json/1` but raises `Skir.DecodeError` on failure."
      @spec from_json!(binary()) :: t()
      def from_json!(bin, opts \\ []) when is_binary(bin) do
        keep = if Keyword.get(opts, :keep, false), do: :keep, else: :drop
        term = JSON.decode!(bin)
        __skir_decode_json__(term, [], keep)
      end
    end
  end

  # --- compile-time validation ---

  defp validate_numbering!(module, variants, removed) do
    nums = Enum.map(variants, & &1.number) ++ removed
    dups = nums -- Enum.uniq(nums)

    if dups != [] do
      raise CompileError,
        description: "#{inspect(module)}: duplicate variant numbers #{inspect(dups)}"
    end

    if 0 in nums do
      raise CompileError,
        description: "#{inspect(module)}: variant number 0 is reserved for :unknown"
    end
  end
end

defmodule Skir.Enum.Compiler do
  @moduledoc false
  # Builds the runtime TypeAdapter/Serializer for an enum.

  alias Skir.TypeAdapter
  alias Skir.Serializer
  alias Skir.Wire.Number
  alias Skir.Wire.Skip
  alias Skir.TypeDescriptor
  alias Skir.TypeDescriptor.EnumDescriptor
  alias Skir.TypeDescriptor.EnumVariant

  def build_serializer(module, variants, removed, meta) do
    ta = build_type_adapter(module, variants, removed, meta)

    %Serializer{
      type_adapter: ta,
      module: module,
      name: module |> Module.split() |> List.last(),
      qualified_name: meta.qualified_name,
      module_path: meta.module_path,
      doc: meta.doc
    }
  end

  defp build_type_adapter(module, variants, removed, meta) do
    by_number = Map.new(variants, fn v -> {v.number, v} end)
    by_name = Map.new(variants, fn v -> {Atom.to_string(v.name), v} end)

    %TypeAdapter{
      is_default: fn
        :unknown -> true
        {:unknown, _} -> false
        _ -> false
      end,
      to_json: fn v, flavor -> enum_to_json(v, variants, flavor) end,
      decode_json: fn term, path, keep ->
        enum_decode_json(term, by_number, by_name, removed, path, keep)
      end,
      encode_binary: fn v, acc -> enum_encode_binary(v, acc, variants) end,
      decode_binary: fn bits, keep ->
        enum_decode_binary(bits, by_number, removed, keep)
      end,
      type_descriptor: fn ->
        enum_type_descriptor(module, variants, removed, meta)
      end
    }
  end

  # ----- to_json -----

  defp enum_to_json(:unknown, _, :dense), do: 0
  defp enum_to_json(:unknown, _, :readable), do: "unknown"

  defp enum_to_json(
         {:unknown, %Skir.Unrecognized{format: :json, data: term}},
         _variants,
         _flavor
       ),
       do: term

  defp enum_to_json({:unknown, %Skir.Unrecognized{format: :binary}}, _variants, flavor) do
    # Binary-preserved unknown can't render to JSON meaningfully; fall back.
    case flavor do
      :dense -> 0
      :readable -> "unknown"
    end
  end

  defp enum_to_json(atom, variants, :dense) when is_atom(atom) do
    case Enum.find(variants, &(&1.name == atom and &1.kind == :constant)) do
      %{number: n} -> n
      nil -> 0
    end
  end

  defp enum_to_json(atom, _variants, :readable) when is_atom(atom),
    do: Atom.to_string(atom)

  defp enum_to_json({name, payload}, variants, :dense) do
    case Enum.find(variants, &(&1.name == name and &1.kind == :wrapper)) do
      %{number: n, wraps: w} ->
        inner = wrapper_inner_ta(w)
        [n, inner.to_json.(payload, :dense)]

      nil ->
        0
    end
  end

  defp enum_to_json({name, payload}, variants, :readable) do
    case Enum.find(variants, &(&1.name == name and &1.kind == :wrapper)) do
      %{wraps: w} ->
        inner = wrapper_inner_ta(w)
        %{"kind" => Atom.to_string(name), "value" => inner.to_json.(payload, :readable)}

      nil ->
        "unknown"
    end
  end

  # ----- decode_json -----

  defp enum_decode_json(0, _, _, _, _, _), do: :unknown

  defp enum_decode_json(n, by_number, _by_name, removed, _path, keep) when is_integer(n) do
    cond do
      n in removed ->
        :unknown

      Map.has_key?(by_number, n) ->
        case Map.fetch!(by_number, n) do
          %{kind: :constant, name: name} -> name
          %{kind: :wrapper, name: name, wraps: w} -> {name, default_for_inner(w)}
        end

      true ->
        json_unknown(n, keep)
    end
  end

  defp enum_decode_json(s, _by_number, by_name, _removed, _path, _keep) when is_binary(s) do
    key = String.downcase(s)

    case Enum.find(by_name, fn {k, _} -> String.downcase(k) == key end) do
      {_, %{kind: :constant, name: name}} -> name
      _ -> :unknown
    end
  end

  defp enum_decode_json([n, payload] = term, by_number, _by_name, removed, path, keep)
       when is_integer(n) do
    cond do
      n in removed ->
        :unknown

      Map.has_key?(by_number, n) ->
        case Map.fetch!(by_number, n) do
          %{kind: :wrapper, name: name, wraps: w} ->
            inner = wrapper_inner_ta(w)
            {name, inner.decode_json.(payload, path, keep)}

          %{kind: :constant, name: name} ->
            # Wire is in wrapper form [n, payload] but variant n is a constant
            # in this schema (forward-compat): take the constant, drop payload.
            name
        end

      true ->
        json_unknown(term, keep)
    end
  end

  defp enum_decode_json(%{"kind" => k, "value" => v}, _by_number, by_name, _removed, path, keep) do
    case Map.get(by_name, k) do
      %{kind: :wrapper, name: name, wraps: w} ->
        inner = wrapper_inner_ta(w)
        {name, inner.decode_json.(v, path, keep)}

      _ ->
        :unknown
    end
  end

  defp enum_decode_json(_other, _, _, _, _, _keep), do: :unknown

  # Unknown variant in JSON: capture the raw JSON term when keeping, else drop.
  defp json_unknown(term, :keep),
    do: {:unknown, %Skir.Unrecognized{format: :json, data: term}}

  defp json_unknown(_term, :drop), do: :unknown

  # ----- encode_binary -----

  defp enum_encode_binary(:unknown, acc, _), do: [acc, <<0x00>>]

  defp enum_encode_binary({:unknown, %Skir.Unrecognized{format: :binary, data: bytes}}, acc, _),
    do: [acc, bytes]

  defp enum_encode_binary(atom, acc, variants) when is_atom(atom) do
    case Enum.find(variants, &(&1.name == atom and &1.kind == :constant)) do
      %{number: n} -> [acc, Number.encode_uint32(n)]
      nil -> [acc, <<0x00>>]
    end
  end

  defp enum_encode_binary({name, payload}, acc, variants) do
    case Enum.find(variants, &(&1.name == name and &1.kind == :wrapper)) do
      %{number: n, wraps: w} ->
        inner = wrapper_inner_ta(w)

        header =
          if n in 1..4 do
            <<0xFA + n>>
          else
            [<<0xF8>>, Number.encode_uint32(n)]
          end

        inner.encode_binary.(payload, [acc, header])

      nil ->
        [acc, <<0x00>>]
    end
  end

  # Constant context: first byte tells us we have a uint32 variant number.
  defp enum_decode_binary(<<wire, _::bits>> = bits, by_number, removed, keep)
       when wire < 0xF2 do
    case Number.decode_uint32(bits) do
      {:ok, {0, rest}} ->
        {:ok, {:unknown, rest}}

      {:ok, {n, rest}} ->
        resolved = resolve_constant(n, by_number, removed)

        cond do
          resolved != :unknown ->
            {:ok, {resolved, rest}}

          keep == :keep and n not in removed ->
            capture_and_return(bits, rest)

          true ->
            {:ok, {:unknown, rest}}
        end

      {:error, _} = err ->
        err
    end
  end

  # single-byte wrapper header: 0xFB..0xFE means variants 1..4.
  defp enum_decode_binary(<<wire, payload_bits::bits>> = bits, by_number, removed, keep)
       when wire in 0xFB..0xFE do
    n = wire - 0xFA
    decode_wrapper(n, payload_bits, by_number, removed, keep, bits)
  end

  # long wrapper header: 0xF8 + uint32 variant number + payload.
  defp enum_decode_binary(<<0xF8, after_header::bits>> = bits, by_number, removed, keep) do
    case Number.decode_uint32(after_header) do
      {:ok, {n, payload_bits}} ->
        decode_wrapper(n, payload_bits, by_number, removed, keep, bits)

      {:error, _} = err ->
        err
    end
  end

  # fallback: unknown leading byte for enum context — skip and yield :unknown.
  defp enum_decode_binary(<<_, _::bits>> = bits, _by_number, _removed, _keep) do
    case Skip.skip_value(bits) do
      {:ok, rest} -> {:ok, {:unknown, rest}}
      {:error, _} = err -> err
    end
  end

  defp enum_decode_binary(<<>>, _, _, _),
    do: {:error, "unexpected end of input decoding enum"}

  # captures the bytes consumed between `original_bits` and `rest` and
  # returns them wrapped in {:unknown, %Unrecognized{}}.
  defp capture_and_return(original_bits, rest) do
    consumed = byte_size(original_bits) - byte_size(rest)
    <<captured::binary-size(consumed), _::bits>> = original_bits
    unrec = %Skir.Unrecognized{format: :binary, data: captured}
    {:ok, {{:unknown, unrec}, rest}}
  end

  defp resolve_constant(n, by_number, removed) do
    cond do
      n in removed ->
        :unknown

      Map.has_key?(by_number, n) ->
        case Map.fetch!(by_number, n) do
          %{kind: :constant, name: name} -> name
          %{kind: :wrapper, name: name, wraps: w} -> {name, default_for_inner(w)}
        end

      true ->
        :unknown
    end
  end

  defp decode_wrapper(n, bits, by_number, removed, keep, original_bits) do
    cond do
      n in removed ->
        case Skip.skip_value(bits) do
          {:ok, rest} -> {:ok, {:unknown, rest}}
          {:error, _} = err -> err
        end

      Map.has_key?(by_number, n) ->
        case Map.fetch!(by_number, n) do
          %{kind: :wrapper, name: name, wraps: w} ->
            inner = wrapper_inner_ta(w)

            case inner.decode_binary.(bits, keep) do
              {:ok, {v, rest}} -> {:ok, {{name, v}, rest}}
              {:error, _} = err -> err
            end

          %{kind: :constant, name: name} ->
            # Wire is in wrapper form but variant n is a constant in this
            # schema (forward-compat across schema versions): take the
            # constant and skip the payload to keep `rest` aligned.
            case Skip.skip_value(bits) do
              {:ok, rest} -> {:ok, {name, rest}}
              {:error, _} = err -> err
            end
        end

      true ->
        # Truly unknown wrapper variant. Skip the payload.
        case Skip.skip_value(bits) do
          {:ok, rest} ->
            if keep == :keep do
              capture_and_return(original_bits, rest)
            else
              {:ok, {:unknown, rest}}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  # wrapper inner type adapter

  defp wrapper_inner_ta(:bool), do: Serializer.Builtin.bool()
  defp wrapper_inner_ta(:int32), do: Serializer.Builtin.int32()
  defp wrapper_inner_ta(:int64), do: Serializer.Builtin.int64()
  defp wrapper_inner_ta(:hash64), do: Serializer.Builtin.hash64()
  defp wrapper_inner_ta(:float32), do: Serializer.Builtin.float32()
  defp wrapper_inner_ta(:float64), do: Serializer.Builtin.float64()
  defp wrapper_inner_ta(:string), do: Serializer.Builtin.string()
  defp wrapper_inner_ta(:bytes), do: Serializer.Builtin.bytes()
  defp wrapper_inner_ta(:timestamp), do: Serializer.Builtin.timestamp()
  defp wrapper_inner_ta(mod) when is_atom(mod), do: mod.__skir_serializer__().type_adapter

  defp default_for_inner(:bool), do: false
  defp default_for_inner(:int32), do: 0
  defp default_for_inner(:int64), do: 0
  defp default_for_inner(:hash64), do: 0
  defp default_for_inner(:float32), do: 0.0
  defp default_for_inner(:float64), do: 0.0
  defp default_for_inner(:string), do: ""
  defp default_for_inner(:bytes), do: ""
  defp default_for_inner(:timestamp), do: ~U[1970-01-01 00:00:00.000Z]
  defp default_for_inner(mod) when is_atom(mod), do: mod.default()

  # type descriptor
  # Build the TypeDescriptor for this enum: Record(id) + EnumDescriptor with
  # variants, plus transitive closure of records referenced by wrapper variants.
  # Mirrors gleam enum_serializer enum_type_descriptor.
  defp enum_type_descriptor(module, variants, removed, meta) do
    id = meta.module_path <> ":" <> meta.qualified_name

    {variant_descs, all_records} =
      Enum.map_reduce(variants, %{}, fn v, acc ->
        case v.kind do
          :constant ->
            vd = %EnumVariant{
              kind: :constant,
              name: Atom.to_string(v.name),
              number: v.number,
              doc: v.doc || ""
            }

            {vd, acc}

          :wrapper ->
            {sig, records} = variant_type_sig_and_records(v.wraps, module, id)

            vd = %EnumVariant{
              kind: :wrapper,
              name: Atom.to_string(v.name),
              number: v.number,
              variant_type: sig,
              doc: v.doc || ""
            }

            {vd, Map.merge(acc, records)}
        end
      end)

    ed = %EnumDescriptor{
      name: meta.qualified_name |> String.split(".") |> List.last(),
      qualified_name: meta.qualified_name,
      module_path: meta.module_path,
      doc: meta.doc || "",
      removed_numbers: removed,
      variants: variant_descs
    }

    %TypeDescriptor{type_sig: {:record, id}, records: Map.put(all_records, id, {:enum, ed})}
  end

  # For a wrapper variant's inner type: return its TypeSignature + records.
  # For a direct self-reference (recursive enum variant), build the type_sig
  # structurally with EMPTY records — descending would recurse forever
  # (gleam: wrapper_variant with type_sig: Some(sig), records: dict.new()).
  defp variant_type_sig_and_records(wraps, module, self_id) do
    if recursive_self_ref?(wraps, module) do
      {recursive_type_sig(wraps, self_id), %{}}
    else
      inner_td = wrapper_inner_ta(wraps).type_descriptor.()
      {inner_td.type_sig, inner_td.records}
    end
  end

  defp recursive_self_ref?(mod, module) when is_atom(mod), do: mod == module
  defp recursive_self_ref?(_, _), do: false

  defp recursive_type_sig(mod, self_id) when is_atom(mod), do: {:record, self_id}
end
