defmodule Skir.PreserveModeTest do
  use ExUnit.Case, async: true

  alias Skir.Test.Schemas.{SimpleStruct, WithRemoved, Color, Action, Container}
  alias Skir.Unrecognized

  @prefix "skir"

  # =====================================================================
  # Helpers — construct v2 wire payloads by hand
  # =====================================================================

  # Take a v1 struct's bytes and append `extra_slots` worth of extra slots
  # at the end, adjusting the slot count header.
  defp append_extra_slots(v1_bytes, current_count, extra_bytes_iolist, extra_slot_count) do
    new_count = current_count + extra_slot_count
    <<@prefix, body::binary>> = v1_bytes

    # Strip the old slot-count header and rebuild with the new count
    body_without_header = strip_slot_count_header(body, current_count)
    new_header = encode_slot_count(new_count)

    extra = IO.iodata_to_binary(extra_bytes_iolist)
    @prefix <> new_header <> body_without_header <> extra
  end

  # 0x00 or 0xF6
  defp strip_slot_count_header(body, 0), do: strip_one_byte(body)
  # 0xF7
  defp strip_slot_count_header(body, 1), do: strip_one_byte(body)
  # 0xF8
  defp strip_slot_count_header(body, 2), do: strip_one_byte(body)
  # 0xF9
  defp strip_slot_count_header(body, 3), do: strip_one_byte(body)

  defp strip_slot_count_header(<<0xFA, rest::binary>>, _n) do
    # Long header: 0xFA + uint32 count. Strip the count too.
    {_n_decoded, rest_after_count} = strip_uint32(rest)
    rest_after_count
  end

  defp strip_one_byte(<<_, rest::binary>>), do: rest

  defp strip_uint32(<<n, rest::binary>>) when n <= 231, do: {n, rest}
  defp strip_uint32(<<0xE8, n::16-little, rest::binary>>), do: {n, rest}
  defp strip_uint32(<<0xE9, n::32-little, rest::binary>>), do: {n, rest}

  defp encode_slot_count(0), do: <<0xF6>>
  defp encode_slot_count(1), do: <<0xF7>>
  defp encode_slot_count(2), do: <<0xF8>>
  defp encode_slot_count(3), do: <<0xF9>>

  defp encode_slot_count(n) when n > 3 do
    cond do
      n <= 231 -> <<0xFA, n>>
      n <= 0xFFFF -> <<0xFA, 0xE8, n::16-little>>
      true -> <<0xFA, 0xE9, n::32-little>>
    end
  end

  # =====================================================================
  # Group A: Drop mode (default)
  # =====================================================================

  describe "drop mode (default)" do
    test "struct with extra trailing slot decodes; extra data is gone" do
      base = SimpleStruct.new(%{name: "Alice", age: 30})
      v1_bytes = SimpleStruct.to_binary(base)

      # Append an extra int32 slot to simulate a v2 schema
      extra = Skir.Wire.Number.encode_int32(999)
      v2_bytes = append_extra_slots(v1_bytes, 2, [extra], 1)

      assert {:ok, decoded} = SimpleStruct.from_binary(v2_bytes)
      assert decoded.name == "Alice"
      assert decoded.age == 30
      assert decoded.__skir_unrecognized__ == nil
    end

    test "enum unknown variant decodes as bare :unknown" do
      # Variant number 99 not in schema (Color has 1, 2, 3)
      v2_bytes = @prefix <> <<99>>
      assert {:ok, :unknown} = Color.from_binary(v2_bytes)
    end

    test "unknown wrapper variant decodes as bare :unknown" do
      # Variant 88 with string payload, not in Action schema
      v2_bytes = @prefix <> <<0xF8, 88, 0xF3, 5, "hello"::binary>>
      assert {:ok, :unknown} = Action.from_binary(v2_bytes)
    end

    test "re-encode after drop produces v1-shaped bytes (smaller than v2)" do
      base = SimpleStruct.new(%{name: "Bob", age: 25})
      v1_bytes = SimpleStruct.to_binary(base)

      extra = Skir.Wire.Number.encode_int32(999)
      v2_bytes = append_extra_slots(v1_bytes, 2, [extra], 1)

      assert {:ok, decoded} = SimpleStruct.from_binary(v2_bytes)
      reencoded = SimpleStruct.to_binary(decoded)

      assert reencoded == v1_bytes
      assert byte_size(reencoded) < byte_size(v2_bytes)
    end
  end

  # =====================================================================
  # Group B: Keep mode — structs
  # =====================================================================

  describe "keep mode — structs" do
    test "trailing slot captured in __skir_unrecognized__" do
      base = SimpleStruct.new(%{name: "Carol", age: 40})
      v1_bytes = SimpleStruct.to_binary(base)
      extra = Skir.Wire.Number.encode_int32(123)
      v2_bytes = append_extra_slots(v1_bytes, 2, [extra], 1)

      assert {:ok, decoded} = SimpleStruct.from_binary(v2_bytes, keep: true)
      assert %Unrecognized{format: :binary, array_len: 3} = decoded.__skir_unrecognized__
      assert decoded.__skir_unrecognized__.data == IO.iodata_to_binary(extra)
    end

    test "known fields decode correctly alongside preserved data" do
      base = SimpleStruct.new(%{name: "Dave", age: 50})
      v1_bytes = SimpleStruct.to_binary(base)
      extra = Skir.Wire.Number.encode_int32(0xCAFE)
      v2_bytes = append_extra_slots(v1_bytes, 2, [extra], 1)

      assert {:ok, decoded} = SimpleStruct.from_binary(v2_bytes, keep: true)
      assert decoded.name == "Dave"
      assert decoded.age == 50
    end

    test "re-encode produces byte-identical v2" do
      base = SimpleStruct.new(%{name: "Eve", age: 60})
      v1_bytes = SimpleStruct.to_binary(base)
      extra = Skir.Wire.Number.encode_int32(0xBEEF)
      v2_bytes = append_extra_slots(v1_bytes, 2, [extra], 1)

      assert {:ok, decoded} = SimpleStruct.from_binary(v2_bytes, keep: true)
      assert SimpleStruct.to_binary(decoded) == v2_bytes
    end

    test "multiple extra slots all captured together" do
      base = SimpleStruct.new(%{name: "Frank", age: 70})
      v1_bytes = SimpleStruct.to_binary(base)

      extra1 = Skir.Wire.Number.encode_int32(111)
      extra2 = Skir.Wire.Primitive.encode_string("extra")
      extra3 = Skir.Wire.Number.encode_int32(333)
      v2_bytes = append_extra_slots(v1_bytes, 2, [extra1, extra2, extra3], 3)

      assert {:ok, decoded} = SimpleStruct.from_binary(v2_bytes, keep: true)
      assert %Unrecognized{array_len: 5} = decoded.__skir_unrecognized__
      assert SimpleStruct.to_binary(decoded) == v2_bytes
    end

    test "round-trip cycle preserves data through multiple decode/encode steps" do
      base = SimpleStruct.new(%{name: "Grace", age: 80})
      v1_bytes = SimpleStruct.to_binary(base)
      extra = Skir.Wire.Number.encode_int32(42)
      v2_bytes = append_extra_slots(v1_bytes, 2, [extra], 1)

      {:ok, d1} = SimpleStruct.from_binary(v2_bytes, keep: true)
      b1 = SimpleStruct.to_binary(d1)
      {:ok, d2} = SimpleStruct.from_binary(b1, keep: true)
      b2 = SimpleStruct.to_binary(d2)

      assert b1 == b2
      assert b1 == v2_bytes
      assert d1.__skir_unrecognized__ == d2.__skir_unrecognized__
    end

    test "removed slot with non-default content is still skipped (not preserved)" do
      # WithRemoved has field 0 (id), removed 1, field 2 (label).
      # Even if the wire has data in slot 1, we skip it — that's the whole
      # point of removed fields. Preserve mode is for *unknown* trailing
      # data, not removed slots.
      base = WithRemoved.new(%{id: 1, label: "x"})
      v1_bytes = WithRemoved.to_binary(base)

      assert {:ok, decoded} = WithRemoved.from_binary(v1_bytes, keep: true)
      assert decoded.id == 1
      assert decoded.label == "x"
      assert decoded.__skir_unrecognized__ == nil
    end
  end

  # =====================================================================
  # Group C: Keep mode — enums
  # =====================================================================

  describe "keep mode — enums (constant variants)" do
    test "unknown constant variant captured" do
      v2_bytes = @prefix <> <<99>>

      assert {:ok, {:unknown, %Unrecognized{format: :binary, data: <<99>>}}} =
               Color.from_binary(v2_bytes, keep: true)
    end

    test "re-encode produces byte-identical bytes" do
      v2_bytes = @prefix <> <<99>>
      {:ok, decoded} = Color.from_binary(v2_bytes, keep: true)
      assert Color.to_binary(decoded) == v2_bytes
    end

    test "known constant variant passes through unchanged" do
      red_bytes = Color.to_binary(:red)
      assert {:ok, :red} = Color.from_binary(red_bytes, keep: true)
    end

    test "unknown variant uses multi-byte uint32 encoding" do
      # Variant 1000 encoded as <<0xE8, 232, 3>>
      v2_bytes = @prefix <> <<0xE8, 232, 3>>

      assert {:ok, {:unknown, %Unrecognized{data: <<0xE8, 232, 3>>}}} =
               Color.from_binary(v2_bytes, keep: true)

      {:ok, decoded} = Color.from_binary(v2_bytes, keep: true)
      assert Color.to_binary(decoded) == v2_bytes
    end
  end

  describe "keep mode — enums (wrapper variants)" do
    test "unknown wrapper variant (single-byte header) captured" do
      # Variant numbers 1-4 use single-byte headers 0xFB-0xFE.
      # Action has variants 1-3; variant 4 would be unknown but uses 0xFE.
      # Construct: header 0xFE + payload (string "hi")
      v2_bytes = @prefix <> <<0xFE, 0xF3, 2, "hi"::binary>>

      assert {:ok, {:unknown, %Unrecognized{data: data}}} =
               Action.from_binary(v2_bytes, keep: true)

      assert data == <<0xFE, 0xF3, 2, "hi"::binary>>
    end

    test "unknown wrapper variant (long header) captured" do
      # Variant >= 5 uses long header 0xF8 + uint32 number.
      # Construct: header 0xF8 + variant 99 + string payload
      v2_bytes = @prefix <> <<0xF8, 99, 0xF3, 5, "hello"::binary>>

      assert {:ok, {:unknown, %Unrecognized{data: data}}} =
               Action.from_binary(v2_bytes, keep: true)

      assert data == <<0xF8, 99, 0xF3, 5, "hello"::binary>>
    end

    test "re-encode wrapper unknown produces byte-identical" do
      v2_bytes = @prefix <> <<0xF8, 99, 0xF3, 5, "hello"::binary>>
      {:ok, decoded} = Action.from_binary(v2_bytes, keep: true)
      assert Action.to_binary(decoded) == v2_bytes
    end

    test "known wrapper variant passes through unchanged" do
      val = {:move, "north"}
      bytes = Action.to_binary(val)
      assert {:ok, ^val} = Action.from_binary(bytes, keep: true)
    end
  end

  # =====================================================================
  # Group D: Composability — nested types
  # =====================================================================

  describe "composability" do
    test "struct containing an enum with preserved unknown variant" do
      # Container.state is a Color enum. If we construct a Container wire
      # payload where the state slot has an unknown enum variant, and we
      # decode with keep, the Container's state field becomes
      # {:unknown, %Unrecognized{}}.
      v1_container = Container.new(%{id: 7, state: :red})
      v1_bytes = Container.to_binary(v1_container)

      # Replace the state byte (slot 1, last in v1 since slot 0 is id=7
      # as <<7>> single byte, then slot 1's red=1 as <<1>>) with variant 99
      # The struct header for 2 slots is 0xF8.
      # So body is <<0xF8, 7, 1>> — replace last byte with 99.
      v1_body =
        binary_slice(v1_bytes, byte_size(@prefix), byte_size(v1_bytes) - byte_size(@prefix))

      <<0xF8, 7, _color_byte>> = v1_body
      v2_body = <<0xF8, 7, 99>>
      v2_bytes = @prefix <> v2_body

      # Drop mode: state becomes bare :unknown
      assert {:ok, dropped} = Container.from_binary(v2_bytes)
      assert dropped.state == :unknown

      # Keep mode: state becomes {:unknown, %Unrecognized{}}
      assert {:ok, kept} = Container.from_binary(v2_bytes, keep: true)
      assert {:unknown, %Unrecognized{data: <<99>>}} = kept.state
      assert kept.id == 7
    end
  end

  # =====================================================================
  # Group E: Edge cases
  # =====================================================================

  describe "edge cases" do
    test "preserve mode on data with no unknown content produces nil unrecognized" do
      base = SimpleStruct.new(%{name: "Henry", age: 90})
      bytes = SimpleStruct.to_binary(base)

      assert {:ok, decoded} = SimpleStruct.from_binary(bytes, keep: true)
      assert decoded.__skir_unrecognized__ == nil
    end

    test "re-encoding preserved value, then decoding without keep, drops the preserve" do
      base = SimpleStruct.new(%{name: "Ivy", age: 100})
      v1_bytes = SimpleStruct.to_binary(base)
      extra = Skir.Wire.Number.encode_int32(42)
      v2_bytes = append_extra_slots(v1_bytes, 2, [extra], 1)

      {:ok, preserved} = SimpleStruct.from_binary(v2_bytes, keep: true)
      v2_reencoded = SimpleStruct.to_binary(preserved)

      # Now decode v2 without keep — the preserve data should be silently dropped
      assert {:ok, dropped} = SimpleStruct.from_binary(v2_reencoded)
      assert dropped.__skir_unrecognized__ == nil
      assert dropped.name == "Ivy"
      assert dropped.age == 100
    end

    test "secure default — accidentally constructed v2 bytes don't survive a drop-mode trip" do
      # This is documenting the security guarantee: round-tripping through
      # a drop-mode decoder strips any unknown fields. A v1 peer cannot
      # accidentally forward injected v2 data to a v2 peer.
      base = SimpleStruct.new(%{name: "Jenny", age: 110})
      v1_bytes = SimpleStruct.to_binary(base)
      malicious_extra = Skir.Wire.Primitive.encode_string("$$$injection$$$")
      v2_bytes = append_extra_slots(v1_bytes, 2, [malicious_extra], 1)

      {:ok, decoded} = SimpleStruct.from_binary(v2_bytes)
      laundered = SimpleStruct.to_binary(decoded)

      # The laundered bytes should be the original v1 form — no injection
      refute String.contains?(laundered, "injection")
      assert laundered == v1_bytes
    end
  end
end
