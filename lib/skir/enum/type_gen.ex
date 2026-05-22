defmodule Skir.Enum.TypeGen do
  @moduledoc false
  # Builds AST for the `@type t :: ...` of a Skir enum.
  #
  # A Skir enum's runtime values are:
  #   - bare atom for constant variants: :free
  #   - tagged tuple for wrapper variants: {:trial, payload}
  #   - :unknown atom for unrecognized variants (drop mode)
  #   - {:unknown, %Unrecognized{}} for keep mode

  @doc """
  Returns AST for the body of `@type t :: <union>`.

  The union always includes `:unknown` and `{:unknown, Skir.Unrecognized.t()}`
  as forward-compat escape hatches.
  """
  def union_ast(variants) when is_list(variants) do
    variant_types = Enum.map(variants, &variant_type_ast/1)

    unknown_types = [
      quote(do: :unknown),
      quote(do: {:unknown, Skir.Unrecognized.t()})
    ]

    fold_union(variant_types ++ unknown_types)
  end

  # --- single variant ---

  defp variant_type_ast(%{kind: :constant, name: name}) do
    # Literal atom in typespec AST
    name
  end

  defp variant_type_ast(%{kind: :wrapper, name: name, wraps: wraps}) do
    payload_ast = payload_type_ast(wraps)
    quote do: {unquote(name), unquote(payload_ast)}
  end

  # --- payload type for wraps ---

  defp payload_type_ast(:bool), do: quote(do: boolean())
  defp payload_type_ast(:int32), do: quote(do: Skir.Types.int32())
  defp payload_type_ast(:int64), do: quote(do: Skir.Types.int64())
  defp payload_type_ast(:hash64), do: quote(do: Skir.Types.hash64())
  defp payload_type_ast(:float32), do: quote(do: Skir.Types.float32())
  defp payload_type_ast(:float64), do: quote(do: Skir.Types.float64())
  defp payload_type_ast(:string), do: quote(do: String.t())
  defp payload_type_ast(:bytes), do: quote(do: Skir.Types.bytes())
  defp payload_type_ast(:timestamp), do: quote(do: Skir.Types.timestamp())

  defp payload_type_ast(mod) when is_atom(mod) do
    quote do: unquote(mod).t()
  end

  # --- fold list into pipe-union ---

  defp fold_union([single]), do: single

  defp fold_union([first | rest]) do
    quote do: unquote(first) | unquote(fold_union(rest))
  end
end
