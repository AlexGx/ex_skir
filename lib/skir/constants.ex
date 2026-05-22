defmodule Skir.Constants do
  @moduledoc """
  Compile-time constants from a Skir schema.

      defmodule SkirOut.Constants do
        use Skir.Constants
        defconst :tarzan, SkirOut.User, %{user_id: 123, name: "Tarzan", ...}
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Skir.Constants, only: [defconst: 3]
    end
  end

  defmacro defconst(name, type, value) do
    body =
      case type do
        {:__aliases__, _, _} = mod_ast ->
          quote(do: unquote(mod_ast).partial(unquote(value)))

        _ ->
          value
      end

    quote do
      def unquote(name)(), do: unquote(body)
    end
  end
end
