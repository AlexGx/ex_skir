defmodule SkirOut.Pet do
  @moduledoc false

  use Skir.Struct, id: 421_887_321

  field :name, :string, 0
  field :height_in_meters, :float32, 1
  field :picture, :string, 2
end

defmodule SkirOut.Trial do
  @moduledoc false

  use Skir.Struct
  field :start_time, :timestamp, 0
end

defmodule SkirOut.SubscriptionStatus do
  @moduledoc false

  use Skir.Enum, id: 100_200_300

  variant :free, 1
  variant :trial, 2, wraps: SkirOut.Trial
  variant :premium, 3
end

defmodule SkirOut.User do
  @moduledoc false

  use Skir.Struct, id: 500_996_846

  field :user_id, :int64, 0
  field :name, :string, 1
  removed 2
  field :quote, :string, 3
  field :pets, {:array, SkirOut.Pet}, 4
  field :subscription_status, SkirOut.SubscriptionStatus, 5
  field :nickname, {:optional, :string}, 6
end

defmodule SkirOut.UserRegistry do
  @moduledoc false

  use Skir.Struct
  field :users, {:array, SkirOut.User, key: :user_id}, 0
end

defmodule SkirOut.Constants do
  @moduledoc false

  use Skir.Constants

  defconst :supported_locales, {:array, :string}, ["en-US", "ja-JP", "fr-FR"]
end
