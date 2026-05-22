defmodule Skir.SerializerPrimitivesTest do
  use ExUnit.Case, async: true

  alias Skir.Serializer
  alias Skir.Serializer.Builtin

  # ---- helpers ----

  defp ser(type_adapter), do: %Serializer{type_adapter: type_adapter, module: nil}

  defp to_dense(adapter, value),
    do: Serializer.encode_json(ser(adapter), value, :dense)

  defp to_readable(adapter, value),
    do: Serializer.encode_json(ser(adapter), value, :readable)

  defp from_json(adapter, str),
    do: Serializer.decode_json(ser(adapter), str)

  defp to_bytes(adapter, value),
    do: Serializer.encode_binary(ser(adapter), value)

  defp from_bytes(adapter, bytes),
    do: Serializer.decode_binary(ser(adapter), bytes)

  @prefix "skir"

  # =====================================================================
  # bool
  # =====================================================================

  describe "bool — to_dense_json" do
    test "true is 1", do: assert(to_dense(Builtin.bool(), true) == "1")
    test "false is 0", do: assert(to_dense(Builtin.bool(), false) == "0")
  end

  describe "bool — to_readable_json" do
    test "true is true", do: assert(to_readable(Builtin.bool(), true) == "true")
    test "false is false", do: assert(to_readable(Builtin.bool(), false) == "false")
  end

  describe "bool — from_json" do
    test "literal true", do: assert({:ok, true} = from_json(Builtin.bool(), "true"))
    test "literal false", do: assert({:ok, false} = from_json(Builtin.bool(), "false"))
    test "number 1", do: assert({:ok, true} = from_json(Builtin.bool(), "1"))
    test "number 0", do: assert({:ok, false} = from_json(Builtin.bool(), "0"))

    test "number nonzero is true", do: assert({:ok, true} = from_json(Builtin.bool(), "42"))

    test "float zero is false", do: assert({:ok, false} = from_json(Builtin.bool(), "0.0"))

    test "string \"0\" is false", do: assert({:ok, false} = from_json(Builtin.bool(), "\"0\""))

    test "string \"1\" is true", do: assert({:ok, true} = from_json(Builtin.bool(), "\"1\""))

    test "null is false", do: assert({:ok, false} = from_json(Builtin.bool(), "null"))
  end

  describe "bool — binary" do
    test "true wire byte is 0x01", do: assert(to_bytes(Builtin.bool(), true) == @prefix <> <<1>>)

    test "false wire byte is 0x00",
      do: assert(to_bytes(Builtin.bool(), false) == @prefix <> <<0>>)

    test "round-trip true" do
      assert {:ok, true} = from_bytes(Builtin.bool(), to_bytes(Builtin.bool(), true))
    end

    test "round-trip false" do
      assert {:ok, false} = from_bytes(Builtin.bool(), to_bytes(Builtin.bool(), false))
    end
  end

  # =====================================================================
  # int32
  # =====================================================================

  describe "int32 — to_json" do
    test "zero", do: assert(to_dense(Builtin.int32(), 0) == "0")
    test "positive", do: assert(to_dense(Builtin.int32(), 42) == "42")
    test "negative", do: assert(to_dense(Builtin.int32(), -1) == "-1")

    test "same in dense and readable" do
      adapter = Builtin.int32()
      assert to_dense(adapter, 12_345) == to_readable(adapter, 12_345)
    end
  end

  describe "int32 — from_json" do
    test "integer", do: assert({:ok, 42} = from_json(Builtin.int32(), "42"))
    test "negative", do: assert({:ok, -1} = from_json(Builtin.int32(), "-1"))
    test "zero", do: assert({:ok, 0} = from_json(Builtin.int32(), "0"))

    test "string of integer" do
      assert {:ok, 7} = from_json(Builtin.int32(), "\"7\"")
    end

    test "float truncates", do: assert({:ok, 3} = from_json(Builtin.int32(), "3.9"))

    test "unparseable string is 0",
      do: assert({:ok, 0} = from_json(Builtin.int32(), "\"abc\""))

    test "null is 0", do: assert({:ok, 0} = from_json(Builtin.int32(), "null"))
  end

  describe "int32 — binary encoding" do
    test "0 is single byte 0x00",
      do: assert(to_bytes(Builtin.int32(), 0) == @prefix <> <<0x00>>)

    test "1 is single byte 0x01",
      do: assert(to_bytes(Builtin.int32(), 1) == @prefix <> <<0x01>>)

    test "231 is single byte 0xE7",
      do: assert(to_bytes(Builtin.int32(), 231) == @prefix <> <<231>>)

    test "1000 uses u16 marker" do
      # 1000 = 0x03E8 LE: 232, 3 → wire 0xE8 + LE bytes
      assert to_bytes(Builtin.int32(), 1000) == @prefix <> <<0xE8, 232, 3>>
    end

    test "65536 uses u32 marker" do
      assert to_bytes(Builtin.int32(), 65_536) == @prefix <> <<0xE9, 0, 0, 1, 0>>
    end

    test "-1 uses u8-neg marker" do
      assert to_bytes(Builtin.int32(), -1) == @prefix <> <<0xEB, 255>>
    end

    test "-300 uses u16-neg marker" do
      # -300 + 65536 = 65236 = 0xFED4 LE: 212, 254
      assert to_bytes(Builtin.int32(), -300) == @prefix <> <<0xEC, 212, 254>>
    end

    test "-100_000 uses i32 marker" do
      # -100000 as u32 = 0xFFFE7960 LE: 96, 121, 254, 255
      assert to_bytes(Builtin.int32(), -100_000) == @prefix <> <<0xED, 96, 121, 254, 255>>
    end
  end

  describe "int32 — binary round-trip" do
    @cases [0, 1, 42, 231, 232, 300, 65_535, 65_536, -1, -255, -256, -65_536]

    for v <- @cases do
      test "round-trip #{inspect(v)}" do
        v = unquote(v)
        adapter = Builtin.int32()
        assert {:ok, ^v} = from_bytes(adapter, to_bytes(adapter, v))
      end
    end
  end

  # =====================================================================
  # int64
  # =====================================================================

  describe "int64 — to_json" do
    test "safe integers stay as numbers" do
      assert to_dense(Builtin.int64(), 0) == "0"
      assert to_dense(Builtin.int64(), 9_007_199_254_740_991) == "9007199254740991"
      assert to_dense(Builtin.int64(), -9_007_199_254_740_991) == "-9007199254740991"
    end

    test "large values are quoted strings" do
      assert to_dense(Builtin.int64(), 9_007_199_254_740_992) == "\"9007199254740992\""
      assert to_dense(Builtin.int64(), -9_007_199_254_740_992) == "\"-9007199254740992\""
    end
  end

  describe "int64 — from_json" do
    test "integer", do: assert({:ok, 42} = from_json(Builtin.int64(), "42"))
    test "negative", do: assert({:ok, -1} = from_json(Builtin.int64(), "-1"))

    test "quoted large" do
      assert {:ok, 9_007_199_254_740_992} =
               from_json(Builtin.int64(), "\"9007199254740992\"")
    end

    test "null is 0", do: assert({:ok, 0} = from_json(Builtin.int64(), "null"))
  end

  describe "int64 — binary" do
    test "fits in i32 uses i32 encoding" do
      assert to_bytes(Builtin.int64(), 0) == @prefix <> <<0x00>>
      assert to_bytes(Builtin.int64(), 42) == @prefix <> <<42>>
    end

    test "above i32 max uses i64 marker" do
      # 2_147_483_648 = i32 max + 1 → wire 0xEE + i64 LE
      v = 2_147_483_648

      assert to_bytes(Builtin.int64(), v) ==
               @prefix <> <<0xEE, 0, 0, 0, 128, 0, 0, 0, 0>>
    end

    test "round-trip across ranges" do
      adapter = Builtin.int64()

      for v <- [
            0,
            1,
            231,
            232,
            65_536,
            2_147_483_647,
            2_147_483_648,
            9_007_199_254_740_991,
            -1,
            -2_147_483_648
          ] do
        assert {:ok, ^v} = from_bytes(adapter, to_bytes(adapter, v))
      end
    end
  end

  # =====================================================================
  # hash64
  # =====================================================================

  describe "hash64 — to_json" do
    test "safe integer", do: assert(to_dense(Builtin.hash64(), 0) == "0")

    test "safe boundary" do
      assert to_dense(Builtin.hash64(), 9_007_199_254_740_991) == "9007199254740991"
    end

    test "large value quoted" do
      assert to_dense(Builtin.hash64(), 9_007_199_254_740_992) == "\"9007199254740992\""
    end
  end

  describe "hash64 — from_json" do
    test "integer", do: assert({:ok, 42} = from_json(Builtin.hash64(), "42"))

    test "quoted large" do
      assert {:ok, 9_007_199_254_740_992} =
               from_json(Builtin.hash64(), "\"9007199254740992\"")
    end

    test "null is 0", do: assert({:ok, 0} = from_json(Builtin.hash64(), "null"))

    test "negative number is 0", do: assert({:ok, 0} = from_json(Builtin.hash64(), "-1.0"))
  end

  describe "hash64 — binary" do
    test "single byte range" do
      assert to_bytes(Builtin.hash64(), 0) == @prefix <> <<0>>
      assert to_bytes(Builtin.hash64(), 231) == @prefix <> <<231>>
    end

    test "u16 range" do
      assert to_bytes(Builtin.hash64(), 1000) == @prefix <> <<0xE8, 232, 3>>
    end

    test "u32 range" do
      assert to_bytes(Builtin.hash64(), 65_536) == @prefix <> <<0xE9, 0, 0, 1, 0>>
    end

    test "u64 range" do
      v = 4_294_967_296
      assert to_bytes(Builtin.hash64(), v) == @prefix <> <<0xEA, 0, 0, 0, 0, 1, 0, 0, 0>>
    end

    test "round-trip" do
      adapter = Builtin.hash64()

      for v <- [0, 1, 231, 232, 65_535, 65_536, 4_294_967_295, 4_294_967_296] do
        assert {:ok, ^v} = from_bytes(adapter, to_bytes(adapter, v))
      end
    end
  end

  # =====================================================================
  # float32
  # =====================================================================

  describe "float32 — to_json" do
    test "zero", do: assert(to_dense(Builtin.float32(), 0.0) == "0.0")
    test "one and half", do: assert(to_dense(Builtin.float32(), 1.5) == "1.5")
    test "negative", do: assert(to_dense(Builtin.float32(), -3.14) == "-3.14")
  end

  describe "float32 — from_json" do
    test "number", do: assert({:ok, 1.5} = from_json(Builtin.float32(), "1.5"))
    test "integer becomes float", do: assert({:ok, 3.0} = from_json(Builtin.float32(), "3"))

    test "null is 0.0" do
      assert {:ok, v} = from_json(Builtin.float32(), "null")
      assert v == 0.0
    end

    test "quoted number", do: assert({:ok, 1.5} = from_json(Builtin.float32(), "\"1.5\""))

    test "NaN literal", do: assert({:ok, :nan} = from_json(Builtin.float32(), "\"NaN\""))
  end

  describe "float32 — binary" do
    test "zero is single byte zero" do
      assert to_bytes(Builtin.float32(), 0.0) == @prefix <> <<0x00>>
    end

    test "nonzero starts with wire 0xF0" do
      <<@prefix, 0xF0, _::binary>> = to_bytes(Builtin.float32(), 1.5)
    end

    test "round-trip zero" do
      adapter = Builtin.float32()
      assert {:ok, v} = from_bytes(adapter, to_bytes(adapter, 0.0))
      assert v == 0.0
    end

    test "round-trip 1.5" do
      adapter = Builtin.float32()
      assert {:ok, 1.5} = from_bytes(adapter, to_bytes(adapter, 1.5))
    end

    test "round-trip negative" do
      adapter = Builtin.float32()
      assert {:ok, -1.5} = from_bytes(adapter, to_bytes(adapter, -1.5))
    end
  end

  # =====================================================================
  # float64
  # =====================================================================

  describe "float64 — to_json" do
    test "zero", do: assert(to_dense(Builtin.float64(), 0.0) == "0.0")
    test "1.5", do: assert(to_dense(Builtin.float64(), 1.5) == "1.5")
    test "negative", do: assert(to_dense(Builtin.float64(), -3.14) == "-3.14")
  end

  describe "float64 — binary" do
    test "zero is single byte zero" do
      assert to_bytes(Builtin.float64(), 0.0) == @prefix <> <<0x00>>
    end

    test "nonzero starts with wire 0xF1" do
      <<@prefix, 0xF1, _::binary>> = to_bytes(Builtin.float64(), 1.5)
    end

    test "round-trip pi" do
      adapter = Builtin.float64()
      v = 3.141_592_653_589_793
      assert {:ok, ^v} = from_bytes(adapter, to_bytes(adapter, v))
    end

    test "round-trip -e" do
      adapter = Builtin.float64()
      v = -2.718_281_828_459_045
      assert {:ok, ^v} = from_bytes(adapter, to_bytes(adapter, v))
    end
  end

  # =====================================================================
  # string
  # =====================================================================

  describe "string — to_json" do
    test "empty", do: assert(to_dense(Builtin.string(), "") == "\"\"")
    test "simple", do: assert(to_dense(Builtin.string(), "hello") == "\"hello\"")

    test "escapes double-quote" do
      assert to_dense(Builtin.string(), "say \"hi\"") == "\"say \\\"hi\\\"\""
    end

    test "escapes backslash" do
      assert to_dense(Builtin.string(), "a\\b") == "\"a\\\\b\""
    end

    test "escapes newline" do
      assert to_dense(Builtin.string(), "a\nb") == "\"a\\nb\""
    end
  end

  describe "string — from_json" do
    test "string", do: assert({:ok, "hello"} = from_json(Builtin.string(), "\"hello\""))
    test "empty", do: assert({:ok, ""} = from_json(Builtin.string(), "\"\""))

    test "number is empty", do: assert({:ok, ""} = from_json(Builtin.string(), "0"))

    test "null is empty", do: assert({:ok, ""} = from_json(Builtin.string(), "null"))

    test "round-trip" do
      adapter = Builtin.string()

      assert {:ok, "round trip"} =
               from_json(adapter, to_dense(adapter, "round trip"))
    end
  end

  describe "string — binary" do
    test "empty is wire 0xF2" do
      assert to_bytes(Builtin.string(), "") == @prefix <> <<0xF2>>
    end

    test "hello" do
      # 0xF3 + length 5 + utf8 bytes of "hello"
      assert to_bytes(Builtin.string(), "hello") ==
               @prefix <> <<0xF3, 5, 104, 101, 108, 108, 111>>
    end

    test "round-trip empty" do
      adapter = Builtin.string()
      assert {:ok, ""} = from_bytes(adapter, to_bytes(adapter, ""))
    end

    test "round-trip simple" do
      adapter = Builtin.string()
      assert {:ok, "hello"} = from_bytes(adapter, to_bytes(adapter, "hello"))
    end

    test "round-trip unicode" do
      adapter = Builtin.string()
      v = "héllo wörld"
      assert {:ok, ^v} = from_bytes(adapter, to_bytes(adapter, v))
    end
  end

  # =====================================================================
  # bytes
  # =====================================================================

  describe "bytes — to_dense_json (base64)" do
    test "empty", do: assert(to_dense(Builtin.bytes(), <<>>) == "\"\"")

    test "<<0>>", do: assert(to_dense(Builtin.bytes(), <<0>>) == "\"AA==\"")
    test "<<0,1>>", do: assert(to_dense(Builtin.bytes(), <<0, 1>>) == "\"AAE=\"")
    test "<<0,1,2>>", do: assert(to_dense(Builtin.bytes(), <<0, 1, 2>>) == "\"AAEC\"")

    test "hello bytes" do
      assert to_dense(Builtin.bytes(), "hello") == "\"aGVsbG8=\""
    end
  end

  describe "bytes — to_readable_json (hex:)" do
    test "empty", do: assert(to_readable(Builtin.bytes(), <<>>) == "\"hex:\"")
    test "<<0x0f>>", do: assert(to_readable(Builtin.bytes(), <<0x0F>>) == "\"hex:0f\"")

    test "deadbeef" do
      assert to_readable(Builtin.bytes(), <<0xDE, 0xAD, 0xBE, 0xEF>>) ==
               "\"hex:deadbeef\""
    end
  end

  describe "bytes — from_json" do
    test "base64 decode" do
      assert {:ok, "hello"} = from_json(Builtin.bytes(), "\"aGVsbG8=\"")
    end

    test "empty", do: assert({:ok, ""} = from_json(Builtin.bytes(), "\"\""))

    test "hex: prefix" do
      assert {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>} =
               from_json(Builtin.bytes(), "\"hex:deadbeef\"")
    end

    test "null is empty", do: assert({:ok, ""} = from_json(Builtin.bytes(), "null"))

    test "number is empty", do: assert({:ok, ""} = from_json(Builtin.bytes(), "0"))
  end

  describe "bytes — binary" do
    test "empty is wire 0xF4" do
      assert to_bytes(Builtin.bytes(), <<>>) == @prefix <> <<0xF4>>
    end

    test "hello bytes" do
      assert to_bytes(Builtin.bytes(), "hello") ==
               @prefix <> <<0xF5, 5, 104, 101, 108, 108, 111>>
    end

    test "round-trip empty" do
      adapter = Builtin.bytes()
      assert {:ok, ""} = from_bytes(adapter, to_bytes(adapter, ""))
    end

    test "round-trip" do
      adapter = Builtin.bytes()
      v = <<1, 2, 3, 4, 5, 255, 0, 127>>
      assert {:ok, ^v} = from_bytes(adapter, to_bytes(adapter, v))
    end
  end

  # =====================================================================
  # timestamp
  # =====================================================================

  @epoch ~U[1970-01-01 00:00:00.000Z]
  # 1_234_567_890_000 ms
  @testdate ~U[2009-02-13 23:31:30.000Z]

  describe "timestamp — to_json" do
    test "epoch dense", do: assert(to_dense(Builtin.timestamp(), @epoch) == "0")

    test "nonzero dense" do
      assert to_dense(Builtin.timestamp(), @testdate) == "1234567890000"
    end
  end

  describe "timestamp — from_json" do
    test "integer millis" do
      testdate = @testdate
      assert {:ok, ^testdate} = from_json(Builtin.timestamp(), "1234567890000")
    end

    test "null is epoch" do
      epoch = @epoch
      assert {:ok, ^epoch} = from_json(Builtin.timestamp(), "null")
    end
  end

  describe "timestamp — binary" do
    test "epoch is single byte zero" do
      assert to_bytes(Builtin.timestamp(), @epoch) == @prefix <> <<0x00>>
    end

    test "nonzero starts with wire 0xEF" do
      <<@prefix, 0xEF, _::binary>> = to_bytes(Builtin.timestamp(), @testdate)
    end

    test "round-trip epoch" do
      adapter = Builtin.timestamp()
      epoch = @epoch
      assert {:ok, ^epoch} = from_bytes(adapter, to_bytes(adapter, epoch))
    end

    test "round-trip nonzero" do
      adapter = Builtin.timestamp()
      testdate = @testdate
      assert {:ok, ^testdate} = from_bytes(adapter, to_bytes(adapter, testdate))
    end
  end
end
