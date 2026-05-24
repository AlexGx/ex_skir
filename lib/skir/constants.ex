defmodule Skir.Constants do
  @moduledoc """
  Compile-time constants from a Skir schema.

      defmodule SkirOut.Constants do
        use Skir.Constants
        defconst :tarzan, SkirOut.User, %SkirOut.User{user_id: 123, name: "Tarzan"}
        defconst :status, SkirOut.SubscriptionStatus, {:trial, %SkirOut.Trial{}}
        defconst :pi, :float64, 3.14159
      end

  The generated value expression is already complete (a struct literal,
  a `Mod.partial(...)` call for partial constants, a tagged tuple for enum
  variants, or a primitive), so `defconst` simply defines a zero-arity
  function returning it. The `type` argument is kept for documentation.
  """

  defmacro __using__(_opts) do
    quote do
      import Skir.Constants, only: [defconst: 3]
    end
  end

  defmacro defconst(name, _type, value) do
    quote do
      def unquote(name)(), do: unquote(value)
    end
  end
end
