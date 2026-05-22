defmodule Skir.KeyedList do
  @moduledoc """
  An ordered list of structs indexed by a key field, providing O(1) lookup
  while preserving wire-format compatibility with a plain list.

  ## Use

      registry.users[42]         # Access via `[]`
      Map.fetch(registry.users, 42)  # not supported — use Skir.KeyedList.fetch/2

      {:ok, john} = Skir.KeyedList.fetch(registry.users, 42)
      john = Skir.KeyedList.fetch!(registry.users, 42)
      false = Skir.KeyedList.has_key?(registry.users, 999)

      # Iteration: works like a list — yields each item, not {key, value} pairs
      for user <- registry.users, do: IO.puts(user.name)
      names = Enum.map(registry.users, & &1.name)

      # `get_in` works through Access
      name = get_in(registry, [:users, 42, Access.key(:name)])

  ## Wire format

  Encoded identically to a plain array — the keyed-ness is purely runtime
  sugar. v1 of a schema can declare `[User]` and v2 can declare
  `[User|user_id]` (or vice versa) and the bytes round-trip.

  ## Invariants

    * `items` is the canonical ordered representation (used for serialization).
    * `index` is derived from `items` and `key_field`; never mutate one
      without the other.
    * Duplicate keys: the last item in `items` wins in the index (matches
      Skir spec behavior).
  """

  @enforce_keys [:items, :key_field, :index]
  defstruct [:items, :key_field, :index]

  @type t :: %__MODULE__{
          items: [struct()],
          key_field: atom(),
          index: %{term() => struct()}
        }

  @doc """
  Build a `%KeyedList{}` from a list of structs, indexing by `key_field`.

      iex> Skir.KeyedList.new([%{user_id: 1, name: "a"}, %{user_id: 2, name: "b"}], :user_id)
      %Skir.KeyedList{...}
  """
  @spec new([struct() | map()], atom()) :: t()
  def new(items, key_field) when is_list(items) and is_atom(key_field) do
    %__MODULE__{
      items: items,
      key_field: key_field,
      index: build_index(items, key_field)
    }
  end

  @doc "Empty keyed list with the given key field."
  @spec empty(atom()) :: t()
  def empty(key_field) when is_atom(key_field) do
    %__MODULE__{items: [], key_field: key_field, index: %{}}
  end

  @doc "Look up an item by key. Returns `{:ok, item}` or `:error`."
  @impl true
  @spec fetch(t(), term()) :: {:ok, struct()} | :error
  def fetch(%__MODULE__{index: idx}, key), do: Map.fetch(idx, key)

  @doc "Look up an item by key. Raises `KeyError` if absent."
  @spec fetch!(t(), term()) :: struct()
  def fetch!(%__MODULE__{} = kl, key) do
    case fetch(kl, key) do
      {:ok, v} -> v
      :error -> raise KeyError, key: key, term: kl
    end
  end

  @doc "Look up an item by key. Returns `default` if absent."
  @spec get(t(), term(), term()) :: struct() | term()
  def get(%__MODULE__{index: idx}, key, default \\ nil),
    do: Map.get(idx, key, default)

  @doc "Returns `true` if the given key exists."
  @spec has_key?(t(), term()) :: boolean()
  def has_key?(%__MODULE__{index: idx}, key), do: Map.has_key?(idx, key)

  @doc "Number of items."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{items: items}), do: length(items)

  @doc "Returns the underlying ordered list of items."
  @spec to_list(t()) :: [struct()]
  def to_list(%__MODULE__{items: items}), do: items

  @doc "Returns the list of keys in iteration order."
  @spec keys(t()) :: [term()]
  def keys(%__MODULE__{items: items, key_field: kf}),
    do: Enum.map(items, &Map.fetch!(&1, kf))

  # ---- index building ----

  defp build_index(items, key_field) do
    Map.new(items, fn item -> {Map.fetch!(item, key_field), item} end)
  end

  # ---- Access behaviour ----

  @behaviour Access

  @impl Access
  def get_and_update(%__MODULE__{}, _key, _fun) do
    raise ArgumentError,
          "Skir.KeyedList is read-only at runtime; use new/2 to construct a fresh value"
  end

  @impl Access
  def pop(%__MODULE__{}, _key) do
    raise ArgumentError,
          "Skir.KeyedList is read-only at runtime; use new/2 to construct a fresh value"
  end
end

defimpl Enumerable, for: Skir.KeyedList do
  def count(%Skir.KeyedList{items: items}), do: {:ok, length(items)}

  def member?(_, _), do: {:error, __MODULE__}

  def slice(%Skir.KeyedList{items: items}), do: Enumerable.List.slice(items)

  def reduce(%Skir.KeyedList{items: items}, acc, fun),
    do: Enumerable.List.reduce(items, acc, fun)
end

defimpl Inspect, for: Skir.KeyedList do
  import Inspect.Algebra

  def inspect(%Skir.KeyedList{items: items, key_field: key_field}, opts) do
    keys = Enum.map(items, &Map.fetch!(&1, key_field))
    count = length(items)

    concat([
      "#KeyedList<",
      Atom.to_string(key_field),
      ": ",
      to_doc(keys, opts),
      " (",
      Integer.to_string(count),
      " items)>"
    ])
  end
end
