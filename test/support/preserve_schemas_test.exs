defmodule Skir.Test.Schemas do
  @moduledoc false
  # Schemas used exclusively in preserve-mode tests.
end

defmodule Skir.Test.Schemas.SimpleStruct do
  @moduledoc false
  use Skir.Struct
  field(:name, :string, 0)
  field(:age, :int32, 1)
end

defmodule Skir.Test.Schemas.WithRemoved do
  @moduledoc false
  use Skir.Struct
  field(:id, :int32, 0)
  removed(1)
  field(:label, :string, 2)
end

defmodule Skir.Test.Schemas.Color do
  @moduledoc false
  use Skir.Enum
  variant(:red, 1)
  variant(:green, 2)
  variant(:blue, 3)
end

defmodule Skir.Test.Schemas.Action do
  @moduledoc false
  # Wrapper-variant enum for testing wrapper-style preserve
  use Skir.Enum
  variant(:idle, 1)
  variant(:move, 2, wraps: :string)
  variant(:attack, 3, wraps: :int32)
end

defmodule Skir.Test.Schemas.Container do
  @moduledoc false
  # Struct containing an enum — for composability tests
  use Skir.Struct
  field(:id, :int32, 0)
  field(:state, Skir.Test.Schemas.Color, 1)
end
