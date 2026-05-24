# deprecated, can be useful later for non-native JSON support
# defmodule Skir.JSON do
#   @moduledoc """
#   Minimal JSON codec — runs offline without Jason. For real use, swap with
#   Jason: replace `Skir.JSON.encode_to_iodata!` with `Jason.encode_to_iodata!`
#   and `Skir.JSON.decode!` with `Jason.decode!`.
#   """

#   # --- encode ---

#   def encode_to_iodata!(term), do: enc(term)

#   defp enc(nil), do: "null"
#   defp enc(true), do: "true"
#   defp enc(false), do: "false"
#   defp enc(n) when is_integer(n), do: Integer.to_string(n)
#   defp enc(f) when is_float(f), do: Float.to_string(f)
#   defp enc(s) when is_binary(s), do: [?", escape(s), ?"]
#   defp enc(a) when is_atom(a), do: enc(Atom.to_string(a))

#   defp enc(list) when is_list(list),
#     do: [?[, list |> Enum.map(&enc/1) |> intersperse(?,), ?]]

#   defp enc(map) when is_map(map) do
#     inner =
#       map
#       |> Enum.map(fn {k, v} -> [enc(to_string(k)), ?:, enc(v)] end)
#       |> intersperse(?,)

#     [?{, inner, ?}]
#   end

#   defp intersperse([], _), do: []
#   defp intersperse([x], _), do: [x]
#   defp intersperse([h | t], sep), do: [h, sep | intersperse(t, sep)]

#   defp escape(s), do: for(<<c <- s>>, into: <<>>, do: escape_char(c))

#   defp escape_char(?"), do: "\\\""
#   defp escape_char(?\\), do: "\\\\"
#   defp escape_char(?\n), do: "\\n"
#   defp escape_char(?\r), do: "\\r"
#   defp escape_char(?\t), do: "\\t"

#   defp escape_char(c) when c < 0x20,
#     do: :io_lib.format("\\u~4.16.0b", [c]) |> IO.iodata_to_binary()

#   defp escape_char(c), do: <<c>>

#   # --- decode ---

#   def decode!(bin) when is_binary(bin) do
#     {v, rest} = pv(ws(bin))

#     case ws(rest) do
#       "" -> v
#       junk -> raise "trailing JSON data: #{inspect(junk)}"
#     end
#   end

#   defp pv(<<"null", r::binary>>), do: {nil, r}
#   defp pv(<<"true", r::binary>>), do: {true, r}
#   defp pv(<<"false", r::binary>>), do: {false, r}
#   defp pv(<<?", _::binary>> = b), do: ps(b)
#   defp pv(<<?[, _::binary>> = b), do: pa(b)
#   defp pv(<<?{, _::binary>> = b), do: po(b)
#   defp pv(b), do: pn(b)

#   defp ps(<<?", r::binary>>), do: psc(r, [])

#   defp psc(<<?", r::binary>>, acc),
#     do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), r}

#   defp psc(<<?\\, ?", r::binary>>, acc), do: psc(r, [?" | acc])
#   defp psc(<<?\\, ?\\, r::binary>>, acc), do: psc(r, [?\\ | acc])
#   defp psc(<<?\\, ?/, r::binary>>, acc), do: psc(r, [?/ | acc])
#   defp psc(<<?\\, ?n, r::binary>>, acc), do: psc(r, [?\n | acc])
#   defp psc(<<?\\, ?r, r::binary>>, acc), do: psc(r, [?\r | acc])
#   defp psc(<<?\\, ?t, r::binary>>, acc), do: psc(r, [?\t | acc])

#   defp psc(<<?\\, ?u, h::binary-size(4), r::binary>>, acc) do
#     cp = String.to_integer(h, 16)
#     psc(r, [<<cp::utf8>> | acc])
#   end

#   defp psc(<<c, r::binary>>, acc), do: psc(r, [c | acc])

#   defp pa(<<?[, r::binary>>) do
#     case ws(r) do
#       <<?], r2::binary>> -> {[], r2}
#       r2 -> pai(r2, [])
#     end
#   end

#   defp pai(b, acc) do
#     {v, r} = pv(ws(b))

#     case ws(r) do
#       <<?,, r2::binary>> -> pai(r2, [v | acc])
#       <<?], r2::binary>> -> {Enum.reverse([v | acc]), r2}
#     end
#   end

#   defp po(<<?{, r::binary>>) do
#     case ws(r) do
#       <<?}, r2::binary>> -> {%{}, r2}
#       r2 -> pop(r2, %{})
#     end
#   end

#   defp pop(b, acc) do
#     {k, r1} = ps(ws(b))
#     <<?:, r2::binary>> = ws(r1)
#     {v, r3} = pv(ws(r2))

#     case ws(r3) do
#       <<?,, r4::binary>> -> pop(r4, Map.put(acc, k, v))
#       <<?}, r4::binary>> -> {Map.put(acc, k, v), r4}
#     end
#   end

#   defp pn(b) do
#     {num, r} = tn(b, [])
#     s = num |> Enum.reverse() |> IO.iodata_to_binary()

#     parsed =
#       if String.contains?(s, ".") or String.contains?(s, "e") or String.contains?(s, "E"),
#         do: String.to_float(s),
#         else: String.to_integer(s)

#     {parsed, r}
#   end

#   defp tn(<<c, r::binary>>, acc)
#        when c in ?0..?9 or c in [?-, ?+, ?., ?e, ?E],
#        do: tn(r, [c | acc])

#   defp tn(r, acc), do: {acc, r}

#   defp ws(<<c, r::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: ws(r)
#   defp ws(b), do: b
# end
