# End-to-end SkirRPC smoke test.
# Tests the schema DSL, service registration, and the wire protocol
# by calling handle_request/4 directly (no HTTP).

defmodule SkirRpcSmoke.Methods do
  use Skir.Methods

  method :square, 1001, request: :float32, response: :float32, doc: "Square a number"
  method :greet,  1002, request: :string,  response: :string,  doc: "Greet by name"
end

defmodule SkirRpcSmoke.Service do
  use Skir.Service, methods: SkirRpcSmoke.Methods

  @impl true
  def square(n, _meta), do: {:ok, n * n}

  @impl true
  def greet("", _meta), do: {:error, Skir.ServiceError.bad_request("name required")}
  def greet(name, _meta), do: {:ok, "Hello, #{name}!"}
end

IO.puts("\n=== Method reflection ===")
m = SkirRpcSmoke.Methods.square_method()
IO.puts("name: #{m.name}, number: #{m.number}, doc: #{m.doc}")

IO.puts("\n=== Build cached service ===")
service = SkirRpcSmoke.Service.service()
IO.puts("registered methods: #{map_size(service.by_name)}")

# ----- direct dispatch -----

IO.puts("\n=== Colon format dispatch (the client wire format) ===")
body = "Square:1001::5.0"
{resp, _} = Skir.Service.handle_request(service, body, nil, nil)
IO.puts("status: #{resp.status_code}, body: #{resp.data}")

IO.puts("\n=== JSON envelope dispatch ===")
body = ~s({"method": "Greet", "request": "World"})
{resp, _} = Skir.Service.handle_request(service, body, nil, nil)
IO.puts("status: #{resp.status_code}, body: #{resp.data}")

IO.puts("\n=== ServiceError from handler ===")
body = ~s({"method": "Greet", "request": ""})
{resp, _} = Skir.Service.handle_request(service, body, nil, nil)
IO.puts("status: #{resp.status_code}, body: #{resp.data}")

IO.puts("\n=== Method not found ===")
body = "Nonexistent:9999::true"
{resp, _} = Skir.Service.handle_request(service, body, nil, nil)
IO.puts("status: #{resp.status_code}, body: #{resp.data}")

IO.puts("\n=== List endpoint ===")
{resp, _} = Skir.Service.handle_request(service, "list", nil, nil)
IO.puts("status: #{resp.status_code}, body: #{resp.data}")

IO.puts("\n=== Studio endpoint ===")
{resp, _} = Skir.Service.handle_request(service, "", nil, nil)
IO.puts("status: #{resp.status_code}, content-type: #{resp.content_type}")
IO.puts("html size: #{byte_size(resp.data)} bytes")

# ----- client round-trip (in-process, no HTTP) -----

IO.puts("\n=== Client → Service round-trip (no network) ===")

# Build a fake send_fn that goes through Skir.Service directly:
fake_send = fn req ->
  {response, _} = Skir.Service.handle_request(service, req.body, nil, nil)

  {:ok,
   %{
     status: response.status_code,
     headers: [{"content-type", response.content_type}],
     body: response.data
   }}
end

client = Skir.ServiceClient.new("http://fake/api", send_fn: fake_send)

{:ok, squared} = Skir.ServiceClient.invoke(client, SkirRpcSmoke.Methods.square_method(), 7.0)
IO.puts("Square(7.0) → #{squared}")

{:ok, greeting} = Skir.ServiceClient.invoke(client, SkirRpcSmoke.Methods.greet_method(), "Alex")
IO.puts("Greet(Alex) → #{greeting}")

{:error, err} = Skir.ServiceClient.invoke(client, SkirRpcSmoke.Methods.greet_method(), "")
IO.puts("Greet('') → error status=#{err.status_code} msg=#{err.message}")

IO.puts("\n=== Done ===")
