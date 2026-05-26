defmodule Skir.Method do
  @moduledoc """
  A SkirRPC method definition: a typed RPC signature with a stable
  numeric identifier.

  A method record carries enough information for both the client and server
  sides to encode and decode requests and responses:

    * `name` — string identifier (matches the schema declaration)
    * `number` — stable numeric identifier
    * `doc` — optional documentation string
    * `request_serializer`  — `%Skir.Serializer{}` for the request type
    * `response_serializer` — `%Skir.Serializer{}` for the response type

  Use `Skir.Methods` to declare methods in your schema; do not construct
  this struct directly.
  """

  @enforce_keys [:name, :number, :request_serializer, :response_serializer]
  defstruct [:name, :number, :request_serializer, :response_serializer, doc: ""]

  @type t :: %__MODULE__{
          name: String.t(),
          number: pos_integer(),
          doc: String.t(),
          request_serializer: Skir.Serializer.t(),
          response_serializer: Skir.Serializer.t()
        }
end

defmodule Skir.Methods do
  @moduledoc """
  DSL for declaring SkirRPC methods.

  ## Example

      defmodule SkirOut.Schema.Methods do
        use Skir.Methods

        method :square, 1001,
          request: :float32,
          response: :float32,
          doc: "Square a number"

        method :get_user, 1002,
          request: SkirOut.GetUserRequest,
          response: SkirOut.User
      end

  After `use`, the macro generates one zero-arity function per method
  that returns a `%Skir.Method{}`:

      SkirOut.Schema.Methods.square_method()
      # => %Skir.Method{name: "Square", number: 1001, ...}

  The generated function name is `<snake_name>_method` — `:square` becomes
  `square_method/0`, `:get_user` becomes `get_user_method/0`.

  ## Naming

  The `:name` field in the produced `%Skir.Method{}` is the PascalCase
  form of the atom you declared:

    * `:square`    → `"Square"`
    * `:get_user`  → `"GetUser"`
    * `:list_pets` → `"ListPets"`

  This matches the on-wire name expected by clients and other Skir
  runtimes. The Elixir-side function name stays snake_case.

  ## Compile-time validation

  Duplicate method numbers raise `CompileError`. Method numbers must be
  positive (the Skir spec reserves 0 for unknown/error states).
  """

  defmacro __using__(_opts) do
    quote do
      import Skir.Methods, only: [method: 2, method: 3]
      Module.register_attribute(__MODULE__, :__skir_methods__, accumulate: true)
      @before_compile Skir.Methods
    end
  end

  @doc "Declare a method. See module docs."
  defmacro method(name, number, opts \\ []) do
    request_ast = Keyword.fetch!(opts, :request)
    response_ast = Keyword.fetch!(opts, :response)
    doc = Keyword.get(opts, :doc, "")

    request_resolved = Skir.Struct.Resolver.resolve(request_ast, __CALLER__)
    response_resolved = Skir.Struct.Resolver.resolve(response_ast, __CALLER__)

    quote do
      @__skir_methods__ %{
        name: unquote(name),
        number: unquote(number),
        doc: unquote(doc),
        request: unquote(Macro.escape(request_resolved)),
        response: unquote(Macro.escape(response_resolved))
      }
    end
  end

  defmacro __before_compile__(env) do
    methods = env.module |> Module.get_attribute(:__skir_methods__) |> Enum.reverse()

    nums = Enum.map(methods, & &1.number)
    dups = nums -- Enum.uniq(nums)

    if dups != [] do
      raise CompileError,
        description: "#{inspect(env.module)}: duplicate method numbers #{inspect(dups)}"
    end

    if Enum.any?(nums, &(&1 <= 0)) do
      raise CompileError,
        description: "#{inspect(env.module)}: method numbers must be positive (0 is reserved)"
    end

    method_defs =
      Enum.map(methods, fn m ->
        # fn_name = String.to_atom("#{m.name}_method")
        fn_name = String.to_atom(m.name)
        wire_name = camelize(m.name)
        doc_text = method_doc(m, wire_name)

        quote do
          @doc unquote(doc_text)
          @spec unquote(fn_name)() :: Skir.Method.t()
          def unquote(fn_name)() do
            %Skir.Method{
              name: unquote(wire_name),
              number: unquote(m.number),
              doc: unquote(m.doc),
              request_serializer:
                Skir.Methods.__build_serializer__(unquote(Macro.escape(m.request))),
              response_serializer:
                Skir.Methods.__build_serializer__(unquote(Macro.escape(m.response)))
            }
          end
        end
      end)

    quote do
      @doc """
      Reflection: list of all methods declared in this module.

      Returns a list of maps with `:name`, `:number`, `:doc`, `:request`,
      and `:response` fields — the raw schema metadata.
      """
      @spec __skir_methods__() :: [map()]
      def __skir_methods__ do
        unquote(Macro.escape(methods))
      end

      unquote_splicing(method_defs)
    end
  end

  @doc false
  def __build_serializer__(type_expr) do
    type_adapter = Skir.Struct.Compiler.type_adapter_for(type_expr)

    %Skir.Serializer{
      type_adapter: type_adapter,
      module: nil,
      name: inspect(type_expr),
      qualified_name: inspect(type_expr)
    }
  end

  # Builds @doc text for a generated `<name>_method/0` function.
  # If the user provided `doc:` in the schema, use it; otherwise generate
  # a sensible default mentioning the wire name.
  defp method_doc(%{doc: ""}, wire_name) do
    "Returns the `%Skir.Method{}` record for the `#{wire_name}` RPC method."
  end

  defp method_doc(%{doc: user_doc}, wire_name) when is_binary(user_doc) and user_doc != "" do
    """
    Returns the `%Skir.Method{}` record for the `#{wire_name}` RPC method.

    #{user_doc}
    """
  end

  defp camelize(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> Macro.camelize()
  end
end
