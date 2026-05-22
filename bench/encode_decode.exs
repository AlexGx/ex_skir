# Benchmark encode/decode for various struct sizes and types.
# Run: mix run bench/encode_decode.exs

# Use the existing example schema:
alias SkirOut.{User, Pet}

# --- Test data ---

simple_pet = Pet.new(%{name: "Dumbo", height_in_meters: 1.0, picture: "🐘"})

small_user = User.new(%{
  user_id: 42,
  name: "John Doe",
  quote: "",
  pets: [],
  subscription_status: :free,
  nickname: nil
})

medium_user = User.new(%{
  user_id: 42,
  name: "John Doe",
  quote: "Coffee is just a socially acceptable form of rage.",
  pets: [simple_pet, simple_pet, simple_pet],
  subscription_status: :free,
  nickname: "johndoe"
})

# Pre-encode for decode benchmarks
small_bytes = User.to_binary(small_user)
medium_bytes = User.to_binary(medium_user)
small_json = User.to_json(small_user)
medium_json = User.to_json(medium_user)

IO.puts("Small user encoded: #{byte_size(small_bytes)} bytes binary, #{byte_size(small_json)} bytes JSON")
IO.puts("Medium user encoded: #{byte_size(medium_bytes)} bytes binary, #{byte_size(medium_json)} bytes JSON")

# --- Benchmarks ---

Benchee.run(
  %{
    "encode_binary small" => fn -> User.to_binary(small_user) end,
    "encode_binary medium" => fn -> User.to_binary(medium_user) end,
    "encode_json small" => fn -> User.to_json(small_user) end,
    "encode_json medium" => fn -> User.to_json(medium_user) end,
    "decode_binary small" => fn -> User.from_binary(small_bytes) end,
    "decode_binary medium" => fn -> User.from_binary(medium_bytes) end,
    "decode_json small" => fn -> User.from_json(small_json) end,
    "decode_json medium" => fn -> User.from_json!(medium_json) end,
    "encode + decode binary medium" => fn ->
      medium_user |> User.to_binary() |> User.from_binary!()
    end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  formatters: [
    {Benchee.Formatters.Console, comparison: true, extended_statistics: true}
  ]
)
