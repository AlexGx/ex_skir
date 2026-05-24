defmodule Skir.SerializerCompositesTest do
  @moduledoc """
  Ports the optional/list serializer cases and the float special-value cases
  from the Gleam `serializers_test.gleam` that the existing
  `Skir.SerializerPrimitivesTest` does not cover.

  Representation differences from Gleam are intentional:
    * Gleam maps "Infinity"/"-Infinity" to ±max-float and "NaN" to 0.0.
      We keep them as the atoms :infinity / :neg_infinity / :nan, matching
      Skir.Wire.Primitive.
    * Gleam uses Some/None for optional; we use a bare value / nil.
  """
  use ExUnit.Case, async: true

  alias Skir.Serializer
  alias Skir.Serializer.Builtin

  # ---- helpers (mirror SerializerPrimitivesTest) ----

  defp ser(type_adapter), do: %Serializer{type_adapter: type_adapter, module: nil}
  defp to_dense(a, v), do: Serializer.encode_json(ser(a), v, :dense)
  defp to_readable(a, v), do: Serializer.encode_json(ser(a), v, :readable)
  defp from_json(a, s), do: Serializer.decode_json(ser(a), s)
  defp to_bytes(a, v), do: Serializer.encode_binary(ser(a), v)
  defp from_bytes(a, b), do: Serializer.decode_binary(ser(a), b)

  @prefix "skir"

  # =====================================================================
  # float32 / float64 — special values (Infinity / -Infinity / NaN)
  # =====================================================================

  describe "float special values — to_json" do
    test "float32 infinity atom renders Infinity" do
      assert to_dense(Builtin.float32(), :infinity) == "\"Infinity\""
    end

    test "float32 neg_infinity atom renders -Infinity" do
      assert to_dense(Builtin.float32(), :neg_infinity) == "\"-Infinity\""
    end

    test "float64 nan atom renders NaN" do
      assert to_dense(Builtin.float64(), :nan) == "\"NaN\""
    end
  end

  describe "float special values — from_json" do
    test "float32 Infinity → :infinity" do
      assert {:ok, :infinity} = from_json(Builtin.float32(), "\"Infinity\"")
    end

    test "float32 -Infinity → :neg_infinity" do
      assert {:ok, :neg_infinity} = from_json(Builtin.float32(), "\"-Infinity\"")
    end

    test "float64 Infinity → :infinity" do
      assert {:ok, :infinity} = from_json(Builtin.float64(), "\"Infinity\"")
    end

    test "float64 NaN → :nan" do
      assert {:ok, :nan} = from_json(Builtin.float64(), "\"NaN\"")
    end
  end

  describe "float special values — binary round-trip" do
    test "float32 infinity" do
      a = Builtin.float32()
      assert {:ok, :infinity} = from_bytes(a, to_bytes(a, :infinity))
    end

    test "float32 neg_infinity" do
      a = Builtin.float32()
      assert {:ok, :neg_infinity} = from_bytes(a, to_bytes(a, :neg_infinity))
    end

    test "float32 nan" do
      a = Builtin.float32()
      assert {:ok, :nan} = from_bytes(a, to_bytes(a, :nan))
    end

    test "float64 infinity" do
      a = Builtin.float64()
      assert {:ok, :infinity} = from_bytes(a, to_bytes(a, :infinity))
    end

    test "float64 neg_infinity" do
      a = Builtin.float64()
      assert {:ok, :neg_infinity} = from_bytes(a, to_bytes(a, :neg_infinity))
    end

    test "float64 nan" do
      a = Builtin.float64()
      assert {:ok, :nan} = from_bytes(a, to_bytes(a, :nan))
    end
  end

  # =====================================================================
  # optional(int32)
  # =====================================================================

  defp opt_i32, do: Builtin.optional(Builtin.int32())

  describe "optional — to_json" do
    test "nil dense is null", do: assert(to_dense(opt_i32(), nil) == "null")
    test "value dense", do: assert(to_dense(opt_i32(), 42) == "42")
    test "nil readable is null", do: assert(to_readable(opt_i32(), nil) == "null")
    test "value readable", do: assert(to_readable(opt_i32(), 42) == "42")
  end

  describe "optional — from_json" do
    test "null → nil", do: assert({:ok, nil} = from_json(opt_i32(), "null"))
    test "value → value", do: assert({:ok, 42} = from_json(opt_i32(), "42"))
  end

  describe "optional — binary" do
    test "nil is wire 0xFF" do
      assert to_bytes(opt_i32(), nil) == @prefix <> <<0xFF>>
    end

    test "some starts with value encoding (0 → 0x00)" do
      # Some(0): optional has no tag byte; inner int32 encodes 0 as 0x00.
      assert to_bytes(opt_i32(), 0) == @prefix <> <<0x00>>
    end

    test "round-trip nil" do
      a = opt_i32()
      assert {:ok, nil} = from_bytes(a, to_bytes(a, nil))
    end

    test "round-trip value" do
      a = opt_i32()
      assert {:ok, 42} = from_bytes(a, to_bytes(a, 42))
    end
  end

  # =====================================================================
  # list(int32)
  # =====================================================================

  defp list_i32, do: Builtin.list(Builtin.int32())

  describe "list — to_json" do
    test "empty dense", do: assert(to_dense(list_i32(), []) == "[]")
    test "nonempty dense", do: assert(to_dense(list_i32(), [1, 2, 3]) == "[1,2,3]")
    test "empty readable", do: assert(to_readable(list_i32(), []) == "[]")
  end

  describe "list — from_json" do
    test "zero is empty (default)", do: assert({:ok, []} = from_json(list_i32(), "0"))
    test "empty array", do: assert({:ok, []} = from_json(list_i32(), "[]"))
    test "nonempty array", do: assert({:ok, [1, 2, 3]} = from_json(list_i32(), "[1,2,3]"))
  end

  describe "list — binary round-trip" do
    test "empty" do
      a = list_i32()
      assert {:ok, []} = from_bytes(a, to_bytes(a, []))
    end

    test "nonempty" do
      a = list_i32()
      assert {:ok, [1, 2, 3]} = from_bytes(a, to_bytes(a, [1, 2, 3]))
    end

    test "empty encodes to array-zero header 0xF6" do
      assert to_bytes(list_i32(), []) == @prefix <> <<0xF6>>
    end
  end
end
