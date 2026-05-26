defmodule Skir.TypeDescriptor.StructField do
  @moduledoc false
  defstruct [:name, :number, :field_type, doc: ""]

  @type t :: %__MODULE__{
          name: String.t(),
          number: integer(),
          field_type: term(),
          doc: String.t()
        }
end

defmodule Skir.TypeDescriptor.StructDescriptor do
  @moduledoc false
  alias Skir.TypeDescriptor.StructField

  defstruct [:name, :qualified_name, :module_path, doc: "", removed_numbers: [], fields: []]

  @type t :: %__MODULE__{
          name: String.t(),
          qualified_name: String.t(),
          module_path: String.t(),
          doc: String.t(),
          removed_numbers: [integer()],
          fields: [StructField.t()]
        }
end

defmodule Skir.TypeDescriptor do
  @moduledoc """
  A self-describing Skir type: a type signature plus all record definitions
  (structs and enums) it references, keyed by their
  `"<module_path>:<qualified_name>"` id.

  Port of the Gleam `skir_client/type_descriptor` module. The JSON format is
  byte-compatible with the Go, Rust, and Gleam skir client implementations
  (a specific pretty-printed layout — `to_json/1` reproduces it exactly).

  ## Representation

    * TypeSignature:
      - `{:primitive, p}` where p in
        `:bool|:int32|:int64|:hash64|:float32|:float64|:timestamp|:string|:bytes`
      - `{:optional, sig}`
      - `{:array, item_sig, key_extractor}` (key_extractor is a string, "" if none)
      - `{:record, id}` where id is `"<module_path>:<qualified_name>"`
    * `%Skir.TypeDescriptor{type_sig: sig, records: %{id => record_descriptor}}`
    * record_descriptor: `{:struct, %StructDescriptor{}}` | `{:enum, %EnumDescriptor{}}`
  """

  alias Skir.TypeDescriptor.{StructDescriptor, StructField, EnumDescriptor, EnumVariant}

  defstruct type_sig: nil, records: %{}

  @type primitive ::
          :bool | :int32 | :int64 | :hash64 | :float32 | :float64 | :timestamp | :string | :bytes

  @type type_sig ::
          {:primitive, primitive()}
          | {:optional, type_sig()}
          | {:array, type_sig(), String.t()}
          | {:record, String.t()}

  @type record_descriptor ::
          {:struct, StructDescriptor.t()} | {:enum, EnumDescriptor.t()}

  @type t :: %__MODULE__{
          type_sig: type_sig(),
          records: %{String.t() => record_descriptor()}
        }

  defmodule EnumVariant do
    @moduledoc false
    # kind: :constant | :wrapper. variant_type only for :wrapper.
    defstruct [:kind, :name, :number, :variant_type, doc: ""]

    @type t :: %__MODULE__{
            kind: :constant | :wrapper,
            name: String.t(),
            number: integer(),
            variant_type: term() | nil,
            doc: String.t()
          }
  end

  defmodule EnumDescriptor do
    @moduledoc false
    defstruct [:name, :qualified_name, :module_path, doc: "", removed_numbers: [], variants: []]

    @type t :: %__MODULE__{
            name: String.t(),
            qualified_name: String.t(),
            module_path: String.t(),
            doc: String.t(),
            removed_numbers: [integer()],
            variants: [EnumVariant.t()]
          }
  end

  # ===========================================================================
  # Primitive <-> string
  # ===========================================================================

  @primitives ~w(bool int32 int64 hash64 float32 float64 timestamp string bytes)a

  defp primitive_to_str(:bool), do: "bool"
  defp primitive_to_str(:int32), do: "int32"
  defp primitive_to_str(:int64), do: "int64"
  defp primitive_to_str(:hash64), do: "hash64"
  defp primitive_to_str(:float32), do: "float32"
  defp primitive_to_str(:float64), do: "float64"
  defp primitive_to_str(:timestamp), do: "timestamp"
  defp primitive_to_str(:string), do: "string"
  defp primitive_to_str(:bytes), do: "bytes"

  defp primitive_from_str(s) do
    a = String.to_atom(s)
    if a in @primitives, do: {:ok, a}, else: {:error, "unknown primitive type: #{s}"}
  end

  # ===========================================================================
  # JSON serialization — builds a Jason.OrderedObject tree, then Jason pretty.
  # The pretty-printed layout is byte-compatible with the Go/Rust/Gleam skir
  # clients (verified against the golden dataset). The OrderedObject preserves
  # the canonical key order; conditional fields (doc, removed_numbers,
  # key_extractor) are omitted when empty; records are sorted root-first then
  # alphabetically; variants by number; removed numbers ascending.
  # ===========================================================================

  @doc """
  Serialize a TypeDescriptor to its canonical pretty-printed JSON string.
  Byte-compatible with the Go/Rust/Gleam skir clients.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = td) do
    td |> to_ordered_object() |> Jason.encode!(pretty: true)
  end

  @doc """
  Build the `Jason.OrderedObject` tree for a TypeDescriptor without encoding it.
  Exposed mainly for testing; `to_json/1` is the usual entry point.
  """
  @spec to_ordered_object(t()) :: Jason.OrderedObject.t()
  def to_ordered_object(%__MODULE__{type_sig: type_sig, records: records}) do
    root_id =
      case type_sig do
        {:record, id} -> id
        _ -> ""
      end

    records_sorted =
      records
      |> Map.to_list()
      |> Enum.sort(fn {ka, _}, {kb, _} ->
        cond do
          ka == root_id and kb != root_id -> true
          kb == root_id and ka != root_id -> false
          true -> ka <= kb
        end
      end)
      |> Enum.map(fn {_id, rd} -> record_descriptor_oo(rd) end)

    oo([
      {"type", type_signature_oo(type_sig)},
      {"records", records_sorted}
    ])
  end

  defp oo(pairs), do: Jason.OrderedObject.new(pairs)

  defp record_descriptor_oo({:struct, s}), do: struct_record_oo(s)
  defp record_descriptor_oo({:enum, e}), do: enum_record_oo(e)

  defp struct_record_id(%StructDescriptor{module_path: mp, qualified_name: qn}),
    do: mp <> ":" <> qn

  defp enum_record_id(%EnumDescriptor{module_path: mp, qualified_name: qn}), do: mp <> ":" <> qn

  defp struct_record_oo(%StructDescriptor{} = s) do
    fields = Enum.map(s.fields, &struct_field_oo/1)

    base = [
      {"kind", "struct"},
      {"id", struct_record_id(s)}
    ]

    base = base ++ doc_pair(s.doc)
    base = base ++ [{"fields", fields}]
    base = base ++ removed_pair(s.removed_numbers)
    oo(base)
  end

  defp struct_field_oo(%StructField{} = f) do
    base = [
      {"name", f.name},
      {"number", f.number},
      {"type", type_signature_oo(f.field_type)}
    ]

    oo(base ++ doc_pair(f.doc))
  end

  defp enum_record_oo(%EnumDescriptor{} = e) do
    variants =
      e.variants
      |> Enum.sort_by(& &1.number)
      |> Enum.map(&enum_variant_oo/1)

    base = [
      {"kind", "enum"},
      {"id", enum_record_id(e)}
    ]

    base = base ++ doc_pair(e.doc)
    base = base ++ [{"variants", variants}]
    base = base ++ removed_pair(e.removed_numbers)
    oo(base)
  end

  defp enum_variant_oo(%EnumVariant{kind: :constant} = v) do
    base = [
      {"name", v.name},
      {"number", v.number}
    ]

    oo(base ++ doc_pair(v.doc))
  end

  defp enum_variant_oo(%EnumVariant{kind: :wrapper} = v) do
    base = [
      {"name", v.name},
      {"number", v.number},
      {"type", type_signature_oo(v.variant_type)}
    ]

    oo(base ++ doc_pair(v.doc))
  end

  # doc/removed are emitted only when non-empty, matching the canonical format.
  defp doc_pair(""), do: []
  defp doc_pair(doc), do: [{"doc", doc}]

  defp removed_pair([]), do: []
  defp removed_pair(nums), do: [{"removed_numbers", Enum.sort(nums)}]

  defp type_signature_oo({:primitive, p}) do
    oo([{"kind", "primitive"}, {"value", primitive_to_str(p)}])
  end

  defp type_signature_oo({:optional, inner}) do
    oo([{"kind", "optional"}, {"value", type_signature_oo(inner)}])
  end

  defp type_signature_oo({:array, item_type, key_extractor}) do
    value_pairs =
      [{"item", type_signature_oo(item_type)}] ++
        case key_extractor do
          "" -> []
          ke -> [{"key_extractor", ke}]
        end

    oo([{"kind", "array"}, {"value", oo(value_pairs)}])
  end

  defp type_signature_oo({:record, id}) do
    oo([{"kind", "record"}, {"value", id}])
  end

  # ===========================================================================
  # JSON parsing (uses stdlib JSON.decode, then reconstructs the structures)
  # ===========================================================================

  @doc """
  Parse a TypeDescriptor from a JSON string produced by this module or by an
  equivalent Go/Rust/Gleam skir client.
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_json(json) when is_binary(json) do
    case safe_decode(json) do
      {:ok, root} -> parse_type_descriptor(root)
      {:error, e} -> {:error, "JSON parse error: #{inspect(e)}"}
    end
  end

  defp safe_decode(json) do
    {:ok, JSON.decode!(json)}
  rescue
    e -> {:error, e}
  end

  defp parse_type_descriptor(root) when is_map(root) do
    records_json = Map.get(root, "records", [])

    with {:ok, records_map} <- build_records_map(records_json, %{}),
         {:ok, type_val} <- fetch(root, "type", "type descriptor JSON missing 'type' field"),
         {:ok, type_sig} <- parse_type_signature(type_val) do
      {:ok, %__MODULE__{type_sig: type_sig, records: records_map}}
    end
  end

  defp parse_type_descriptor(_), do: {:error, "type descriptor JSON root must be an object"}

  defp build_records_map([], acc), do: {:ok, acc}

  defp build_records_map([rec | rest], acc) do
    case parse_and_add_record(rec, acc) do
      {:ok, new_acc} -> build_records_map(rest, new_acc)
      {:error, _} = err -> err
    end
  end

  defp parse_and_add_record(rec, acc) do
    kind = get_string(rec, "kind")
    id = get_string(rec, "id")
    doc = get_string(rec, "doc")
    removed = get_int_array(rec, "removed_numbers")

    with {:ok, {module_path, qualified_name}} <- split_record_id(id) do
      name = last_segment(qualified_name)

      case kind do
        "struct" ->
          with {:ok, fields} <- parse_struct_fields(Map.get(rec, "fields", [])) do
            sd = %StructDescriptor{
              name: name,
              qualified_name: qualified_name,
              module_path: module_path,
              doc: doc,
              removed_numbers: removed,
              fields: fields
            }

            {:ok, Map.put(acc, id, {:struct, sd})}
          end

        "enum" ->
          with {:ok, variants} <- parse_enum_variants(Map.get(rec, "variants", [])) do
            ed = %EnumDescriptor{
              name: name,
              qualified_name: qualified_name,
              module_path: module_path,
              doc: doc,
              removed_numbers: removed,
              variants: variants
            }

            {:ok, Map.put(acc, id, {:enum, ed})}
          end

        _ ->
          {:error, "unknown record kind: #{kind}"}
      end
    end
  end

  defp parse_struct_fields(fields_json) do
    try_map(fields_json, fn f ->
      name = get_string(f, "name")
      number = get_int(f, "number")
      doc = get_string(f, "doc")

      case fetch(f, "type", "struct field \"#{name}\" missing 'type'") do
        {:ok, type_val} ->
          with {:ok, field_type} <- parse_type_signature(type_val) do
            {:ok, %StructField{name: name, number: number, field_type: field_type, doc: doc}}
          end

        {:error, _} = err ->
          err
      end
    end)
  end

  defp parse_enum_variants(variants_json) do
    try_map(variants_json, fn v ->
      name = get_string(v, "name")
      number = get_int(v, "number")
      doc = get_string(v, "doc")

      case Map.fetch(v, "type") do
        :error ->
          {:ok, %EnumVariant{kind: :constant, name: name, number: number, doc: doc}}

        {:ok, type_val} ->
          with {:ok, variant_type} <- parse_type_signature(type_val) do
            {:ok,
             %EnumVariant{
               kind: :wrapper,
               name: name,
               number: number,
               variant_type: variant_type,
               doc: doc
             }}
          end
      end
    end)
  end

  defp parse_type_signature(v) when is_map(v) do
    kind = get_string(v, "kind")

    case Map.fetch(v, "value") do
      :error ->
        {:error, "type signature missing 'value', kind=#{kind}"}

      {:ok, value_json} ->
        case kind do
          "primitive" ->
            if is_binary(value_json) do
              with {:ok, p} <- primitive_from_str(value_json), do: {:ok, {:primitive, p}}
            else
              {:error, "primitive type 'value' must be a string"}
            end

          "optional" ->
            with {:ok, inner} <- parse_type_signature(value_json), do: {:ok, {:optional, inner}}

          "array" ->
            key_ext = get_string(value_json, "key_extractor")

            case fetch(value_json, "item", "array type missing 'item'") do
              {:ok, item_val} ->
                with {:ok, item} <- parse_type_signature(item_val) do
                  {:ok, {:array, item, key_ext}}
                end

              {:error, _} = err ->
                err
            end

          "record" ->
            if is_binary(value_json),
              do: {:ok, {:record, value_json}},
              else: {:error, "record type 'value' must be a string"}

          _ ->
            {:error, "unknown type kind: #{kind}"}
        end
    end
  end

  defp parse_type_signature(_), do: {:error, "type signature must be an object"}

  defp split_record_id(id) do
    case String.split(id, ":", parts: 2) do
      [mp, qn] -> {:ok, {mp, qn}}
      _ -> {:error, "malformed record id (expected 'path:Name'): #{id}"}
    end
  end

  defp last_segment(s) do
    s |> String.split(".") |> List.last() || s
  end

  # ---- JSON helpers ----

  defp fetch(map, key, err_msg) do
    case Map.fetch(map, key) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, err_msg}
    end
  end

  defp get_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp get_string(_, _), do: ""

  defp get_int(map, key) when is_map(map) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp get_int(_, _), do: 0

  defp get_int_array(map, key) when is_map(map) do
    case Map.get(map, key) do
      list when is_list(list) -> Enum.filter(list, &is_integer/1)
      _ -> []
    end
  end

  defp get_int_array(_, _), do: []

  defp try_map(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end
end
