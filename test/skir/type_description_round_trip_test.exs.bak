# test/skir/type_descriptor_round_trip_test.exs
defmodule Skir.TypeDescriptorRoundTripTest do
  @moduledoc """
  Step-1 verification for Skir.TypeDescriptor: every `expected_type_descriptor`
  string in the golden dataset must round-trip byte-identically through
  from_json |> to_json. This exercises the parser + serializer on real
  cross-language descriptor strings (all primitive/optional/array/record/enum
  shapes, including keyed arrays and recursive types) without needing the
  Step-2 adapter integration.
  """
  use ExUnit.Case, async: true

  alias Skir.TypeDescriptor, as: TD

  test "every golden type_descriptor round-trips byte-identically" do
    tds =
      SkirOut.Constants.unit_tests()
      |> Enum.flat_map(&extract_tds/1)
      |> Enum.uniq()

    assert tds != [], "no type descriptors found in dataset"

    failures =
      Enum.reduce(tds, [], fn td_json, acc ->
        case TD.from_json(td_json) do
          {:ok, td} ->
            actual = TD.to_json(td)
            if actual == td_json, do: acc, else: [{:mismatch, td_json, actual} | acc]

          {:error, e} ->
            [{:parse_error, td_json, e} | acc]
        end
      end)

    if failures != [] do
      report =
        failures
        |> Enum.take(3)
        |> Enum.map_join("\n\n", &format_failure/1)

      flunk("""
      #{length(failures)} of #{length(tds)} type descriptor(s) failed round-trip.

      #{report}
      """)
    end
  end

  # Pull expected_type_descriptor out of a reserialize_value assertion.
  # nil (our analogue of Gleam's option.None) means "no descriptor for this case".
  defp extract_tds(%{assertion: {:reserialize_value, input}}) do
    case Map.get(input, :expected_type_descriptor) do
      td when is_binary(td) and td != "" -> [td]
      _ -> []
    end
  end

  defp extract_tds(_), do: []

  defp format_failure({:parse_error, td, e}) do
    "PARSE ERROR: #{inspect(e)}\n--- descriptor ---\n#{td}"
  end

  defp format_failure({:mismatch, expected, actual}) do
    idx =
      Enum.zip(String.graphemes(actual), String.graphemes(expected))
      |> Enum.find_index(fn {a, b} -> a != b end)

    """
    ROUND-TRIP MISMATCH (diff at index #{inspect(idx)}, lens #{String.length(actual)}/#{String.length(expected)})
    --- expected (around diff) ---
    #{String.slice(expected, max(0, (idx || 0) - 50), 100)}
    --- got (around diff) ---
    #{String.slice(actual, max(0, (idx || 0) - 50), 100)}
    """
  end
end
