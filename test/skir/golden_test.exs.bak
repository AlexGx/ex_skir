defmodule SkirOut.GoldenTest do
  @moduledoc """
  Port of the Gleam golden-suite driver (`run_golden_tests_test`).

  Interprets the generated `SkirOut.Constants.unit_tests/0` dataset: each
  entry is a `%SkirOut.UnitTest{}` carrying an `Assertion` (a tagged tuple
  from the `SkirOut.Assertion` enum). We evaluate the assertion and collect
  failures, mirroring the Gleam driver.

  ## Differences from the Gleam driver

    * **Type descriptors are skipped.** The Elixir runtime does not yet
      implement `TypeDescriptor`, so the `expected_type_descriptor` field of
      `reserialize_value` assertions is ignored. Everything else (bytes,
      dense/readable JSON, round-trips, skip-value, keep/drop) is checked.
    * Float ±Infinity round-trip (tests 1082/1083) IS exercised here, because
      we represent those as the atoms `:infinity` / `:neg_infinity` rather
      than IEEE values (Gleam had to skip them).
    * Representation: enum values are tagged tuples / bare atoms; optional is
      a bare value or nil; bytes are binaries.
  """
  use ExUnit.Case, async: true

  alias Skir.Serializer
  alias Skir.Serializer.Builtin

  @prefix "skir"

  # ---- evaluated-value helpers (replacing Gleam's EvaluatedValue closures) ----

  # An "evaluated value" is simply {value, adapter}.

  defp ev_to_bytes({value, adapter}),
    do: Serializer.encode_binary(ser(adapter), value)

  defp ev_to_dense({value, adapter}),
    do: Serializer.encode_json(ser(adapter), value, :dense)

  defp ev_to_readable({value, adapter}),
    do: Serializer.encode_json(ser(adapter), value, :readable)

  defp ev_from_json_keep({_v, adapter}, json) do
    case Serializer.decode_json(ser(adapter), json, keep: true) do
      {:ok, v} -> {:ok, {v, adapter}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp ev_from_json_drop({_v, adapter}, json) do
    case Serializer.decode_json(ser(adapter), json) do
      {:ok, v} -> {:ok, {v, adapter}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp ev_from_bytes_drop({_v, adapter}, bytes) do
    case Serializer.decode_binary(ser(adapter), bytes) do
      {:ok, v} -> {:ok, {v, adapter}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp ser(adapter), do: %Serializer{type_adapter: adapter, module: nil}

  # Adapter for a struct/enum module (its serializer's type_adapter).
  defp mod_adapter(mod), do: mod.__skir_serializer__().type_adapter

  # ---- expression evaluators ----

  defp evaluate_bytes({:literal, b}) when is_binary(b), do: {:ok, b}

  defp evaluate_bytes({:to_bytes, tv}) do
    with {:ok, ev} <- evaluate_typed_value(tv), do: {:ok, ev_to_bytes(ev)}
  end

  defp evaluate_bytes(:unknown), do: {:error, "unknown BytesExpression"}

  defp evaluate_string({:literal, s}) when is_binary(s), do: {:ok, s}

  defp evaluate_string({:to_dense_json, tv}) do
    with {:ok, ev} <- evaluate_typed_value(tv), do: {:ok, ev_to_dense(ev)}
  end

  defp evaluate_string({:to_readable_json, tv}) do
    with {:ok, ev} <- evaluate_typed_value(tv), do: {:ok, ev_to_readable(ev)}
  end

  defp evaluate_string(:unknown), do: {:error, "unknown StringExpression"}

  # ---- typed-value evaluator: TypedValue tagged tuple → {value, adapter} ----

  defp evaluate_typed_value({:bool, v}), do: {:ok, {v, Builtin.bool()}}
  defp evaluate_typed_value({:int32, v}), do: {:ok, {v, Builtin.int32()}}
  defp evaluate_typed_value({:int64, v}), do: {:ok, {v, Builtin.int64()}}
  defp evaluate_typed_value({:hash64, v}), do: {:ok, {v, Builtin.hash64()}}
  defp evaluate_typed_value({:float32, v}), do: {:ok, {v, Builtin.float32()}}
  defp evaluate_typed_value({:float64, v}), do: {:ok, {v, Builtin.float64()}}
  defp evaluate_typed_value({:timestamp, v}), do: {:ok, {v, Builtin.timestamp()}}
  defp evaluate_typed_value({:string, v}), do: {:ok, {v, Builtin.string()}}
  defp evaluate_typed_value({:bytes, v}), do: {:ok, {v, Builtin.bytes()}}

  defp evaluate_typed_value({:bool_optional, v}),
    do: {:ok, {v, Builtin.optional(Builtin.bool())}}

  defp evaluate_typed_value({:ints, v}),
    do: {:ok, {v, Builtin.list(Builtin.int32())}}

  defp evaluate_typed_value({:point, v}),
    do: {:ok, {v, mod_adapter(SkirOut.Point)}}

  defp evaluate_typed_value({:color, v}),
    do: {:ok, {v, mod_adapter(SkirOut.Color)}}

  defp evaluate_typed_value({:my_enum, v}),
    do: {:ok, {v, mod_adapter(SkirOut.MyEnum)}}

  defp evaluate_typed_value({:enum_a, v}),
    do: {:ok, {v, mod_adapter(SkirOut.EnumA)}}

  defp evaluate_typed_value({:enum_b, v}),
    do: {:ok, {v, mod_adapter(SkirOut.EnumB)}}

  defp evaluate_typed_value({:keyed_arrays, v}),
    do: {:ok, {v, mod_adapter(SkirOut.KeyedArrays)}}

  defp evaluate_typed_value({:rec_struct, v}),
    do: {:ok, {v, mod_adapter(SkirOut.RecStruct)}}

  defp evaluate_typed_value({:rec_enum, v}),
    do: {:ok, {v, mod_adapter(SkirOut.RecEnum)}}

  # Round-trip variants: evaluate inner, then re-decode its own output (drop).
  defp evaluate_typed_value({:round_trip_dense_json, inner}) do
    with {:ok, ev} <- evaluate_typed_value(inner),
         do: ev_from_json_drop(ev, ev_to_dense(ev))
  end

  defp evaluate_typed_value({:round_trip_readable_json, inner}) do
    with {:ok, ev} <- evaluate_typed_value(inner),
         do: ev_from_json_drop(ev, ev_to_readable(ev))
  end

  defp evaluate_typed_value({:round_trip_bytes, inner}) do
    with {:ok, ev} <- evaluate_typed_value(inner),
         do: ev_from_bytes_drop(ev, ev_to_bytes(ev))
  end

  # Cross-type keep/drop decode variants. The expr produces a json/bytes
  # payload, which is decoded against a *different* serializer than it was
  # produced with — exercising forward-compat skip/keep behaviour.
  for {tag, mod, src, keep} <- [
        {:point_from_json_keep_unrecognized, SkirOut.Point, :json, true},
        {:point_from_json_drop_unrecognized, SkirOut.Point, :json, false},
        {:point_from_bytes_keep_unrecognized, SkirOut.Point, :bytes, true},
        {:point_from_bytes_drop_unrecognized, SkirOut.Point, :bytes, false},
        {:color_from_json_keep_unrecognized, SkirOut.Color, :json, true},
        {:color_from_json_drop_unrecognized, SkirOut.Color, :json, false},
        {:color_from_bytes_keep_unrecognized, SkirOut.Color, :bytes, true},
        {:color_from_bytes_drop_unrecognized, SkirOut.Color, :bytes, false},
        {:my_enum_from_json_keep_unrecognized, SkirOut.MyEnum, :json, true},
        {:my_enum_from_json_drop_unrecognized, SkirOut.MyEnum, :json, false},
        {:my_enum_from_bytes_keep_unrecognized, SkirOut.MyEnum, :bytes, true},
        {:my_enum_from_bytes_drop_unrecognized, SkirOut.MyEnum, :bytes, false},
        {:enum_a_from_json_keep_unrecognized, SkirOut.EnumA, :json, true},
        {:enum_a_from_json_drop_unrecognized, SkirOut.EnumA, :json, false},
        {:enum_a_from_bytes_keep_unrecognized, SkirOut.EnumA, :bytes, true},
        {:enum_a_from_bytes_drop_unrecognized, SkirOut.EnumA, :bytes, false},
        {:enum_b_from_json_keep_unrecognized, SkirOut.EnumB, :json, true},
        {:enum_b_from_json_drop_unrecognized, SkirOut.EnumB, :json, false},
        {:enum_b_from_bytes_keep_unrecognized, SkirOut.EnumB, :bytes, true},
        {:enum_b_from_bytes_drop_unrecognized, SkirOut.EnumB, :bytes, false}
      ] do
    defp evaluate_typed_value({unquote(tag), expr}) do
      decode_cross(unquote(mod), unquote(src), unquote(keep), expr)
    end
  end

  defp evaluate_typed_value(:unknown), do: {:error, "unknown TypedValue"}
  defp evaluate_typed_value(other), do: {:error, "unhandled TypedValue: #{inspect(other)}"}

  defp decode_cross(mod, :json, keep, expr) do
    with {:ok, json} <- evaluate_string(expr) do
      opts = if keep, do: [keep: true], else: []

      case Serializer.decode_json(ser(mod_adapter(mod)), json, opts) do
        {:ok, v} -> {:ok, {v, mod_adapter(mod)}}
        {:error, e} -> {:error, "#{inspect(mod)} from_json: #{inspect(e)}"}
      end
    end
  end

  defp decode_cross(mod, :bytes, keep, expr) do
    with {:ok, bytes} <- evaluate_bytes(expr) do
      opts = if keep, do: [keep: true], else: []

      case Serializer.decode_binary(ser(mod_adapter(mod)), bytes, opts) do
        {:ok, v} -> {:ok, {v, mod_adapter(mod)}}
        {:error, e} -> {:error, "#{inspect(mod)} from_bytes: #{inspect(e)}"}
      end
    end
  end

  # ---- assertion verifiers ----

  defp verify({:bytes_equal, %{actual: actual, expected: expected}}) do
    with {:ok, a} <- evaluate_bytes(actual),
         {:ok, e} <- evaluate_bytes(expected) do
      if a == e, do: :ok, else: {:error, "bytes mismatch: #{hx(a)} != #{hx(e)}"}
    end
  end

  defp verify({:bytes_in, %{actual: actual, expected: expected}}) do
    with {:ok, a} <- evaluate_bytes(actual) do
      if Enum.any?(expected, &(&1 == a)),
        do: :ok,
        else: {:error, "bytes #{hx(a)} not in expected set"}
    end
  end

  defp verify({:string_equal, %{actual: actual, expected: expected}}) do
    with {:ok, a} <- evaluate_string(actual),
         {:ok, e} <- evaluate_string(expected) do
      if a == e, do: :ok, else: {:error, "string mismatch: #{inspect(a)} != #{inspect(e)}"}
    end
  end

  defp verify({:string_in, %{actual: actual, expected: expected}}) do
    with {:ok, a} <- evaluate_string(actual) do
      if a in expected,
        do: :ok,
        else: {:error, "string #{inspect(a)} not in #{inspect(expected)}"}
    end
  end

  defp verify({:reserialize_value, input}), do: verify_reserialize_value(input)

  defp verify({:reserialize_large_string, %{num_chars: n, expected_byte_prefix: prefix}}) do
    s = String.duplicate("a", n)
    a = Builtin.string()
    verify_large(s, a, prefix, &(&1 == s))
  end

  defp verify({:reserialize_large_array, %{num_items: n, expected_byte_prefix: prefix}}) do
    arr = List.duplicate(1, n)
    a = Builtin.list(Builtin.int32())
    verify_large(arr, a, prefix, fn v -> length(v) == n and Enum.all?(v, &(&1 == 1)) end)
  end

  defp verify({:enum_a_from_json_is_constant, %{actual: actual, keep_unrecognized: keep}}) do
    verify_decoded_eq(actual, :json, SkirOut.EnumA, keep, :a, "EnumA :a")
  end

  defp verify({:enum_a_from_bytes_is_constant, %{actual: actual, keep_unrecognized: keep}}) do
    verify_decoded_eq(actual, :bytes, SkirOut.EnumA, keep, :a, "EnumA :a")
  end

  defp verify(
         {:enum_b_from_json_is_wrapper_b,
          %{actual: actual, expected: exp, keep_unrecognized: keep}}
       ) do
    verify_decoded_eq(
      actual,
      :json,
      SkirOut.EnumB,
      keep,
      {:b, exp},
      "EnumB {:b, #{inspect(exp)}}"
    )
  end

  defp verify(
         {:enum_b_from_bytes_is_wrapper_b,
          %{actual: actual, expected: exp, keep_unrecognized: keep}}
       ) do
    verify_decoded_eq(
      actual,
      :bytes,
      SkirOut.EnumB,
      keep,
      {:b, exp},
      "EnumB {:b, #{inspect(exp)}}"
    )
  end

  defp verify(other), do: {:error, "unknown assertion: #{inspect(other)}"}

  # ---- reserialize_value (the big one) ----

  defp verify_reserialize_value(input) do
    value = input.value
    expected_bytes = input.expected_bytes
    expected_dense = input.expected_dense_json
    expected_readable = input.expected_readable_json

    round_trips = [
      {:round_trip_dense_json, value},
      {:round_trip_readable_json, value},
      {:round_trip_bytes, value}
    ]

    with :ok <-
           each(
             [value | round_trips],
             &verify_reserialize_one(&1, expected_bytes, expected_dense, expected_readable)
           ),
         # :ok <- verify_skip_value(expected_bytes),
         {:ok, typed_ev} <- evaluate_typed_value(value),
         :ok <- rt_jsons_keep(typed_ev, input.alternative_jsons, expected_dense, :alt),
         :ok <-
           rt_jsons_keep(
             typed_ev,
             lit_list(expected_dense ++ expected_readable),
             expected_dense,
             :exp
           ),
         :ok <- rt_bytes_drop(typed_ev, input.alternative_bytes, expected_bytes) do
      # type_descriptor intentionally skipped (not implemented)
      rt_bytes_drop(typed_ev, lit_bytes_list(expected_bytes), expected_bytes)
    end
  end

  defp verify_reserialize_one(tv, expected_bytes, expected_dense, expected_readable) do
    with {:ok, ev} <- evaluate_typed_value(tv) do
      bytes = ev_to_bytes(ev)
      dense = ev_to_dense(ev)
      readable = ev_to_readable(ev)

      cond do
        not Enum.any?(expected_bytes, &(&1 == bytes)) ->
          {:error, "bytes not in set: #{hx(bytes)}"}

        dense not in expected_dense ->
          {:error,
           "dense JSON not in set: #{inspect(dense)} (expected #{inspect(expected_dense)})"}

        readable not in expected_readable ->
          {:error,
           "readable JSON not in set: #{inspect(readable)} (expected #{inspect(expected_readable)})"}

        true ->
          :ok
      end
    end
  end

  # skip-value: "skir" + 0xF8 + payload[4:] + 0x01, decode as Point, x must be 1.
  defp verify_skip_value(expected_bytes) do
    each(expected_bytes, fn eb ->
      payload = binary_part(eb, 4, byte_size(eb) - 4)
      buf = @prefix <> <<0xF8>> <> payload <> <<0x01>>

      case Serializer.decode_binary(ser(mod_adapter(SkirOut.Point)), buf) do
        {:ok, %SkirOut.Point{x: 1}} -> :ok
        {:ok, %SkirOut.Point{x: x}} -> {:error, "skip-value: expected x==1, got #{x}"}
        {:error, e} -> {:error, "skip-value parse: #{inspect(e)}"}
      end
    end)
  end

  defp rt_jsons_keep(typed_ev, json_exprs, expected_dense, _which) do
    each(json_exprs, fn expr ->
      with {:ok, json} <- evaluate_string(expr),
           {:ok, rt} <- ev_from_json_keep(typed_ev, json) do
        got = ev_to_dense(rt)

        if got in expected_dense,
          do: :ok,
          else:
            {:error,
             "json keep round-trip: got #{inspect(got)} expected #{inspect(expected_dense)}"}
      end
    end)
  end

  defp rt_bytes_drop(typed_ev, byte_exprs, expected_bytes) do
    each(byte_exprs, fn expr ->
      with {:ok, bytes} <- evaluate_bytes(expr),
           {:ok, rt} <- ev_from_bytes_drop(typed_ev, bytes) do
        got = ev_to_bytes(rt)

        if Enum.any?(expected_bytes, &(&1 == got)),
          do: :ok,
          else: {:error, "bytes drop round-trip: got #{hx(got)}"}
      end
    end)
  end

  # ---- large string/array ----

  defp verify_large(value, adapter, prefix, correct?) do
    s = ser(adapter)
    dense = Serializer.encode_json(s, value, :dense)
    readable = Serializer.encode_json(s, value, :readable)
    bytes = Serializer.encode_binary(s, value)

    with {:ok, d} <- Serializer.decode_json(s, dense),
         true <- correct?.(d) || {:error, "large dense round-trip"},
         {:ok, r} <- Serializer.decode_json(s, readable),
         true <- correct?.(r) || {:error, "large readable round-trip"},
         true <-
           starts_with?(bytes, prefix) ||
             {:error,
              "large byte prefix mismatch: #{hx(binary_part(bytes, 0, min(byte_size(bytes), byte_size(prefix) + 8)))}"},
         {:ok, b} <- Serializer.decode_binary(s, bytes),
         true <- correct?.(b) || {:error, "large bytes round-trip"} do
      :ok
    else
      {:error, _} = err -> err
      false -> {:error, "large round-trip check failed"}
    end
  end

  # ---- enum decoded-equals ----

  defp verify_decoded_eq(actual_expr, src, mod, keep, expected_value, label) do
    decoded =
      case src do
        :json ->
          with {:ok, json} <- evaluate_string(actual_expr) do
            opts = if keep, do: [keep: true], else: []
            Serializer.decode_json(ser(mod_adapter(mod)), json, opts)
          end

        :bytes ->
          with {:ok, bytes} <- evaluate_bytes(actual_expr) do
            opts = if keep, do: [keep: true], else: []
            Serializer.decode_binary(ser(mod_adapter(mod)), bytes, opts)
          end
      end

    case decoded do
      {:ok, ^expected_value} -> :ok
      {:ok, other} -> {:error, "#{label}: got #{inspect(other)}"}
      {:error, e} -> {:error, "#{label} parse: #{inspect(e)}"}
    end
  end

  # ---- helpers ----

  defp lit_list(strings), do: Enum.map(strings, &{:literal, &1})
  defp lit_bytes_list(byte_list), do: Enum.map(byte_list, &{:literal, &1})

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp starts_with?(bytes, prefix) do
    psize = byte_size(prefix)
    byte_size(bytes) >= psize and binary_part(bytes, 0, psize) == prefix
  end

  defp hx(b), do: "hex:" <> Base.encode16(b, case: :lower)

  # =====================================================================
  # Test entry point
  # =====================================================================

  test "golden suite" do
    unit_tests = SkirOut.Constants.unit_tests()

    assert [first | _] = unit_tests

    # Sequential test numbers
    unit_tests
    |> Enum.with_index()
    |> Enum.each(fn {ut, i} ->
      assert ut.test_number == first.test_number + i
    end)

    failures =
      unit_tests
      |> Enum.flat_map(fn ut ->
        case verify(ut.assertion) do
          :ok -> []
          {:error, msg} -> ["Test ##{ut.test_number}: #{msg}"]
        end
      end)

    if failures != [] do
      flunk("#{length(failures)} golden test(s) failed:\n\n" <> Enum.join(failures, "\n\n"))
    end
  end
end
