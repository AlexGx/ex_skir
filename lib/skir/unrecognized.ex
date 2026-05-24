defmodule Skir.Unrecognized do
  @moduledoc """
  Captures wire-format bytes that this client doesn't recognize, so they
  can be preserved through a decode/re-encode round-trip.

  Set as the value of `__skir_unrecognized__` on a struct, or as the
  second element of `{:unknown, %Unrecognized{}}` on an enum, when
  preserve mode is enabled (`keep: true`).

  Fields:

    * `format` — `:binary` (only binary preserve is implemented in v1)
    * `data` — the raw preserved bytes
    * `array_len` — for struct preserve, the original slot count on the
      wire (so re-encoding produces a byte-identical header). `nil` for
      enums.
  """

  @enforce_keys [:format, :data]
  defstruct [:format, :data, :array_len]

  @type t :: %__MODULE__{
          format: :binary | :json,
          data: binary() | [term()] | term(),
          array_len: non_neg_integer() | nil
        }
end

defimpl Inspect, for: Skir.Unrecognized do
  import Inspect.Algebra

  @spec inspect(Skir.Unrecognized.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(%Skir.Unrecognized{format: format, data: data, array_len: array_len}, _opts) do
    desc =
      case format do
        :binary -> "#{byte_size(data)} byte(s)"
        :json -> "#{length(List.wrap(data))} json item(s)"
      end

    suffix = if array_len, do: ", slots: #{array_len}", else: ""
    concat(["#SkirUnrecognized<", to_string(format), ", ", desc, suffix, ">"])
  end
end
