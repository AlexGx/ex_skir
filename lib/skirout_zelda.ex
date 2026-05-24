# defmodule SkirOut.Constants do
#   @moduledoc false
#   use Skir.Constants

#   # One
#   # constant
#   defconst :one_constant, SkirOut.JsonValue, {:array, [{:boolean, true}, {:number, 2.5}, {:string, "\n        foo\n        bar"}, {:object, [%SkirOut.JsonValue.Pair{name: "foo", value: :null}]}]}
#   # One timestamp
#   defconst :one_timestamp, :timestamp, ~U[2023-12-31 00:53:48Z]
#   defconst :one_single_quoted_string, :string, "\"Foo\""
#   defconst :foo_method, :bool, true
#   defconst :infinity, :float32, :infinity
#   defconst :minus_infinity, :float32, :neg_infinity
#   defconst :nan, :float64, :nan
#   defconst :large_int64, :int64, 9_223_372_036_854_775_807
#   defconst :b, :bool, false
#   defconst :pi, :float64, 3.141592653589793
# end
