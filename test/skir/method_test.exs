defmodule Skir.MethodTest do
  use ExUnit.Case, async: true

  defmodule Methods do
    use Skir.Methods

    method :square, 1001, request: :float32, response: :float32
    method :get_user, 1002, request: :int64, response: :string, doc: "Lookup a user"
    method :list_pets, 1003, request: :string, response: {:array, :string}
  end

  describe "DSL — generated functions" do
    test "generates one method per declaration" do
      assert function_exported?(Methods, :square, 0)
      assert function_exported?(Methods, :get_user, 0)
      assert function_exported?(Methods, :list_pets, 0)
    end

    test "function returns %Skir.Method{}" do
      assert %Skir.Method{} = Methods.square()
    end
  end

  describe "Method record fields" do
    test "name is PascalCase of declared atom" do
      assert Methods.square().name == "Square"
      assert Methods.get_user().name == "GetUser"
      assert Methods.list_pets().name == "ListPets"
    end

    test "number matches declaration" do
      assert Methods.square().number == 1001
      assert Methods.get_user().number == 1002
    end

    test "doc is set when provided, empty when not" do
      assert Methods.get_user().doc == "Lookup a user"
      assert Methods.square().doc == ""
    end

    test "request_serializer is a %Skir.Serializer{}" do
      m = Methods.square()
      assert %Skir.Serializer{} = m.request_serializer
    end

    test "response_serializer is a %Skir.Serializer{}" do
      m = Methods.square()
      assert %Skir.Serializer{} = m.response_serializer
    end
  end

  describe "Reflection — __skir_methods__/0" do
    test "lists all declared methods in source order" do
      methods = Methods.__skir_methods__()
      assert length(methods) == 3
      assert Enum.map(methods, & &1.name) == [:square, :get_user, :list_pets]
    end

    test "each entry has the declared metadata" do
      [first | _] = Methods.__skir_methods__()
      assert first.name == :square
      assert first.number == 1001
      assert first.doc == ""
    end
  end

  describe "Compile-time validation" do
    test "duplicate numbers raise CompileError" do
      ast =
        quote do
          defmodule Skir.MethodTest.DupNums do
            use Skir.Methods
            method :one, 100, request: :int32, response: :int32
            method :two, 100, request: :int32, response: :int32
          end
        end

      assert_raise CompileError, ~r/duplicate method numbers/, fn ->
        Code.compile_quoted(ast)
      end
    end

    test "zero or negative numbers raise CompileError" do
      ast =
        quote do
          defmodule Skir.MethodTest.BadNum do
            use Skir.Methods
            method :bad, 0, request: :int32, response: :int32
          end
        end

      assert_raise CompileError, ~r/method numbers must be positive/, fn ->
        Code.compile_quoted(ast)
      end
    end
  end

  describe "Serializer round-trip via method record" do
    test "request_serializer encodes and decodes float32" do
      m = Methods.square()
      json = Skir.Serializer.encode_json(m.request_serializer, 3.14, :dense)
      assert json == "3.14"

      decoded = Skir.Serializer.decode_json!(m.request_serializer, json)
      assert decoded == 3.14
    end

    test "response_serializer for {:array, :string}" do
      m = Methods.list_pets()
      json = Skir.Serializer.encode_json(m.response_serializer, ["a", "b"], :dense)
      assert json == ~s(["a","b"])

      decoded = Skir.Serializer.decode_json!(m.response_serializer, json)
      assert decoded == ["a", "b"]
    end
  end
end
