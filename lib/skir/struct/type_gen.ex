defmodule Skir.Struct.TypeGen do
  @moduledoc false
  # Builds AST for the `@type t :: %__MODULE__{...}` of a Skir struct,
  # mapping each field's declared type to its Elixir typespec.

  @doc """
  Returns AST for the body of `@type t :: %__MODULE__{...}` — i.e.,
  the map portion with all `field_name: type_spec` entries plus
  `__skir_unrecognized__: Skir.Unrecognized.t() | nil`.
  """
  def field_specs_ast(fields) when is_list(fields) do
    field_pairs =
      Enum.map(fields, fn f ->
        {f.name, type_spec_for(f.type)}
      end)

    unrecognized_spec =
      quote do: Skir.Unrecognized.t() | nil

    field_pairs ++ [{:__skir_unrecognized__, unrecognized_spec}]
  end

  @doc """
  Returns AST for the map type accepted by `new/1`.

  Each field becomes either `required(:field) => type` or
  `optional(:field) => type` based on whether the field is required
  by the schema (non-optional, non-array fields are required).
  """
  def new_input_map_ast(fields) when is_list(fields) do
    pairs = Enum.map(fields, fn f -> new_input_pair_ast(f) end)
    {:%{}, [], pairs}
  end

  @doc """
  Returns AST for the map type accepted by `partial/1`.

  All fields are `optional()` — partial allows any subset of fields.
  """
  def partial_input_map_ast(fields) when is_list(fields) do
    pairs =
      Enum.map(fields, fn f ->
        {{:optional, [], [f.name]}, type_spec_for_input(f.type)}
      end)

    {:%{}, [], pairs}
  end

  # --- internal helpers ---

  # For new/1: required keys for non-optional, non-array fields.
  defp new_input_pair_ast(%{name: name, type: type} = _f) do
    key_wrapper = if input_optional?(type), do: :optional, else: :required
    {{key_wrapper, [], [name]}, type_spec_for_input(type)}
  end

  # Same defaults logic as `optional?/1` in Skir.Struct.
  defp input_optional?({:optional, _}), do: true
  defp input_optional?({:array, _}), do: true
  defp input_optional?({:array, _, _}), do: true
  defp input_optional?(_), do: false

  # Same as type_spec_for but tweaked for input — same logic for now,
  # but separated so we can diverge later (e.g., accepting more lenient
  # types on input than on output).
  defp type_spec_for_input(type), do: type_spec_for(type)

  @doc """
  Maps a single resolved Skir type to its Elixir typespec AST.

  Public so other macros (e.g. `Skir.Service` callbacks) can reuse the
  same type-to-spec mapping.
  """
  def type_spec_for(:bool), do: quote(do: boolean())
  def type_spec_for(:int32), do: quote(do: Skir.Types.int32())
  def type_spec_for(:int64), do: quote(do: Skir.Types.int64())
  def type_spec_for(:hash64), do: quote(do: Skir.Types.hash64())
  def type_spec_for(:float32), do: quote(do: Skir.Types.float32())
  def type_spec_for(:float64), do: quote(do: Skir.Types.float64())
  def type_spec_for(:string), do: quote(do: String.t())
  def type_spec_for(:bytes), do: quote(do: Skir.Types.bytes())
  def type_spec_for(:timestamp), do: quote(do: Skir.Types.timestamp())

  def type_spec_for({:optional, inner}) do
    inner_spec = type_spec_for(inner)
    quote do: unquote(inner_spec) | nil
  end

  def type_spec_for({:array, inner}) do
    inner_spec = type_spec_for(inner)
    quote do: [unquote(inner_spec)]
  end

  def type_spec_for({:array, inner, opts}) when is_list(opts) do
    inner_spec = type_spec_for(inner)
    quote do: Skir.KeyedList.t() | [unquote(inner_spec)]
  end

  def type_spec_for(mod) when is_atom(mod) do
    quote do: unquote(mod).t()
  end
end
