alias SkirOut.{User, Pet, Trial, Constants, SubscriptionStatus, UserRegistry}

IO.puts("\n=== Construction ===")

john =
  # User.new(%{
  %User{
    user_id: 42,
    name: "Joe",
    quote: "Coffee is just a socially acceptable form of rage.",
    pets: [%Pet{name: "Dumbo", height_in_meters: 1.0, picture: "🐘"}],
    subscription_status: :free,
  }

IO.inspect(SubscriptionStatus.module_info(), label: :debug)


IO.inspect(john, label: "john")

jane = User.partial(%{user_id: 43, name: "Jane Doe"})
IO.inspect(jane, label: "jane (partial)")

IO.puts("\n=== Enum pattern matching ===")

trial_user =
  %User{
    user_id: 99,
    name: "Trial T",
    quote: "",
    pets: [],
    subscription_status: {:trial, %Trial{start_time: ~U[2025-04-02 11:13:29.000Z]}},
    nickname: nil
  }

info =
  case trial_user.subscription_status do
    :free -> "Free user"
    :premium -> "Premium user"
    {:trial, %Trial{start_time: t}} -> "On trial since #{t}"
    :unknown -> "Unknown"
  end

IO.inspect(trial_user, label: :debug)
IO.puts(info)

IO.puts("\n=== Dense JSON round-trip ===")

dense_json = User.to_json(john)
IO.puts(dense_json)

{:ok, john_back} = User.from_json(dense_json)
IO.puts("Round-trip matches: #{john == john_back}")

IO.puts("\n=== Readable JSON ===")

readable = User.to_json(john, :readable)
IO.puts(readable)

{:ok, john_back2} = User.from_json(readable)
IO.puts("Round-trip matches: #{john == john_back2}")

IO.puts("\n=== Binary round-trip ===")

bytes = User.to_binary(john)
IO.puts("Encoded #{byte_size(bytes)} bytes (4-byte skir prefix + wire body)")
IO.inspect(bytes, base: :hex, limit: 100)

{:ok, john_bin} = User.from_binary(bytes)
IO.puts("Binary round-trip matches: #{john == john_bin}")

IO.puts("\n=== Constants ===")
IO.inspect(Constants.supported_locales(), label: "locales")

IO.puts("\n=== Reflection ===")
schema = User.__skir_schema__()
IO.puts("Stable id: #{schema.stable_id}")
IO.puts("Removed: #{inspect(schema.removed)}")
IO.puts("Fields:")
for f <- schema.fields do
  IO.puts("  #{f.number}: #{f.name} :: #{inspect(f.type)}")
end

IO.puts("\n=== Preserve mode: trailing slots ===")

pet = %Pet{name: "Dumbo", height_in_meters: 1.0, picture: "🐘"}
v1_pet_bytes = Pet.to_binary(pet)
<<"skir", v1_body::binary>> = v1_pet_bytes
IO.puts("Original pet wire body: #{inspect(v1_body, base: :hex)}")

<<0xF9, pet_body::binary>> = v1_body
extra_slot = IO.iodata_to_binary(Skir.Wire.Number.encode_int32(999))
v2_body = <<0xFA, 4>> <> pet_body <> extra_slot
v2_pet_bytes = "skir" <> v2_body
IO.puts("Constructed v2 pet bytes: #{inspect(v2_pet_bytes, base: :hex)}")

{:ok, dropped} = Pet.from_binary(v2_pet_bytes)
IO.puts("Drop:  name=#{inspect(dropped.name)}, unrecognized=#{inspect(dropped.__skir_unrecognized__)}")

{:ok, preserved} = Pet.from_binary(v2_pet_bytes, keep: true)
IO.puts("Keep:  name=#{inspect(preserved.name)}, unrecognized=#{inspect(preserved.__skir_unrecognized__)}")

reencoded = Pet.to_binary(preserved)
IO.puts("Re-encoded:           #{inspect(reencoded, base: :hex)}")
IO.puts("Re-encoded == v2:     #{reencoded == v2_pet_bytes}")

IO.puts("\n=== Keyed array lookups ===")

registry = SkirOut.UserRegistry.new(%{users: [john, jane]})

# Access via []
IO.inspect(registry.users[42], label: "users[42]")
IO.inspect(registry.users[999], label: "users[999]")

# Skir.KeyedList API
{:ok, j} = Skir.KeyedList.fetch(registry.users, 42)
IO.puts("fetch(42) = #{j.name}")
:error = Skir.KeyedList.fetch(registry.users, 999)
IO.puts("fetch(999) = :error")

# Iteration via Enum
names = Enum.map(registry.users, & &1.name)
IO.inspect(names, label: "names")

# `for` comprehension
for user <- registry.users do
  IO.puts("  user: #{user.name} (id #{user.user_id})")
end

# Size
IO.puts("size: #{Skir.KeyedList.size(registry.users)}")

# get_in
fetched_name = get_in(registry, [Access.key(:users), 42, Access.key(:name)])
IO.puts("get_in name: #{fetched_name}")

# Inspect output
IO.inspect(registry.users, label: "inspect")

# Round-trip: serialize, deserialize, lookups still work
bytes = UserRegistry.to_binary(registry)
{:ok, decoded_registry} = UserRegistry.from_binary(bytes)
IO.puts("After binary round-trip, lookup 42: #{decoded_registry.users[42].name}")
IO.puts("Returned struct type: #{inspect(decoded_registry.users.__struct__)}")

IO.puts("\n=== Enum preserve mode ===")

# Constant unknown variant — number 99.
v2_status_body = <<99>>
v2_status_bytes = "skir" <> v2_status_body
IO.puts("v2 status bytes: #{inspect(v2_status_bytes, base: :hex)}")

{:ok, dropped} = SubscriptionStatus.from_binary(v2_status_bytes)
IO.puts("Drop:  #{inspect(dropped)}")

{:ok, preserved} = SubscriptionStatus.from_binary(v2_status_bytes, keep: true)
IO.puts("Keep:  #{inspect(preserved)}")

reencoded = SubscriptionStatus.to_binary(preserved)
IO.puts("Re-encoded:           #{inspect(reencoded, base: :hex)}")
IO.puts("Re-encoded == v2:     #{reencoded == v2_status_bytes}")

# Wrapper unknown variant — number 88, string payload.
wrapper_v2_body = <<0xF8, 88, 0xF3, 5, "hello"::binary>>
wrapper_v2 = "skir" <> wrapper_v2_body
IO.puts("\nv2 wrapper variant bytes: #{inspect(wrapper_v2, base: :hex)}")

{:ok, dropped_w} = SubscriptionStatus.from_binary(wrapper_v2)
IO.puts("Drop:  #{inspect(dropped_w)}")

{:ok, preserved_w} = SubscriptionStatus.from_binary(wrapper_v2, keep: true)
IO.puts("Keep:  #{inspect(preserved_w)}")

reencoded_w = SubscriptionStatus.to_binary(preserved_w)
IO.puts("Re-encoded == v2:     #{reencoded_w == wrapper_v2}")

IO.puts("\n=== Done ===")
