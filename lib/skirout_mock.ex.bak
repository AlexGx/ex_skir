# defmodule SkirOut.Pet do
#   @moduledoc false

#   use Skir.Struct, id: 421_887_321

#   field :name, :string, 0
#   field :height_in_meters, :float32, 1
#   field :picture, :string, 2
# end

# defmodule SkirOut.Trial do
#   @moduledoc false

#   use Skir.Struct
#   field :start_time, :timestamp, 0
# end

# defmodule SkirOut.SubscriptionStatus do
#   @moduledoc false

#   use Skir.Enum, id: 100_200_300

#   variant :free, 1
#   variant :trial, 2, wraps: SkirOut.Trial
#   variant :premium, 3
# end

# defmodule SkirOut.User do
#   @moduledoc false

#   use Skir.Struct, id: 500_996_846

#   field :user_id, :int64, 0
#   field :name, :string, 1
#   removed 2
#   field :quote, :string, 3
#   field :pets, {:array, SkirOut.Pet}, 4
#   field :subscription_status, SkirOut.SubscriptionStatus, 5
#   field :nickname, {:optional, :string}, 6
# end

# defmodule SkirOut.UserRegistry do
#   @moduledoc false

#   use Skir.Struct
#   field :users, {:array, SkirOut.User, key: :user_id}, 0
# end

# defmodule SkirOut.Constants do
#   @moduledoc false

#   use Skir.Constants

#   defconst :supported_locales, {:array, :string}, ["en-US", "ja-JP", "fr-FR"]
# end

defmodule SkirOut.JsonValue.Pair do
  @moduledoc false

  use Skir.Struct

  field :name, :string, 0
  field :value, SkirOut.JsonValue, 1
end

defmodule SkirOut.JsonValue do
  @moduledoc false

  use Skir.Enum

  variant :null, 1
  variant :string, 3, wraps: :string
  variant :array, 4, wraps: {:array, SkirOut.JsonValue}
  variant :object, 5, wraps: {:array, SkirOut.JsonValue.Pair, key: :name}
  variant :number, 6, wraps: :float64
  # A bool value
  variant :boolean, 100, wraps: :bool
end

defmodule SkirOut.Constants do
  @moduledoc false
  use Skir.Constants

  # One
  # constant
  defconst :one_constant,
           SkirOut.JsonValue,
           {:array,
            [
              {:boolean, true},
              {:number, 2.5},
              {:string, "\n        foo\n        bar"},
              {:object, [%SkirOut.JsonValue.Pair{name: "foo", value: :null}]}
            ]}

  # One timestamp
  defconst :one_timestamp, :timestamp, ~U[2023-12-31 00:53:48Z]
  defconst :one_single_quoted_string, :string, "\"Foo\""
  defconst :foo_method, :bool, true
  defconst :infinity, :float32, :infinity
  defconst :minus_infinity, :float32, :neg_infinity
  defconst :nan, :float64, :nan
  defconst :large_int64, :int64, 9_223_372_036_854_775_807
  defconst :b, :bool, false
  defconst :pi, :float64, 3.141592653589793
end
