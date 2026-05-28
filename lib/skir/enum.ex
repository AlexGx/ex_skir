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
