defmodule Skir.ServiceTest do
  use ExUnit.Case, async: true

  alias Skir.{Service, ServiceError}

  defmodule TestMethods do
    use Skir.Methods

    method :square, 1, request: :float32, response: :float32
    method :greet, 2, request: :string, response: :string
    method :crash, 3, request: :string, response: :string
  end

  # --- handlers ---
  defp square_h(n, _), do: {:ok, n * n}

  defp greet_h("", _), do: {:error, %ServiceError{status: 400, message: "name required"}}
  defp greet_h(name, _), do: {:ok, "Hello, #{name}!"}

  defp crash_h(_, _), do: raise("kaboom")

  defp build_service(opts \\ []) do
    Service.new(opts)
    |> Service.add_method(TestMethods.square_method(), &square_h/2)
    |> Service.add_method(TestMethods.greet_method(), &greet_h/2)
    |> Service.add_method(TestMethods.crash_method(), &crash_h/2)
  end

  describe "new/1 and add_method/3" do
    test "new/0 has empty maps" do
      svc = Service.new()
      assert svc.by_name == %{}
      assert svc.by_number == %{}
    end

    test "add_method registers in both maps" do
      svc =
        Service.new()
        |> Service.add_method(TestMethods.square_method(), &square_h/2)

      assert Map.has_key?(svc.by_name, "Square")
      assert Map.has_key?(svc.by_number, 1)
    end

    test "multiple methods coexist" do
      svc = build_service()
      assert map_size(svc.by_name) == 3
      assert map_size(svc.by_number) == 3
    end

    test "options pass through to struct fields" do
      svc = Service.new(disable_studio: true, disable_list: true, expose_internal_errors: true)
      assert svc.disable_studio == true
      assert svc.disable_list == true
      assert svc.expose_internal_errors == true
    end
  end

  describe "handle_request — colon format" do
    test "successful invocation returns 200 with JSON response" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "Square:1::5.0", nil, nil)
      assert resp.status_code == 200
      assert resp.content_type == "application/json"
      assert resp.data == "25.0"
    end

    test "lookup by name works when number is invalid" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "Square:0::4.0", nil, nil)
      assert resp.status_code == 200
      assert resp.data == "16.0"
    end

    test "lookup by number works when name is wrong" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "WrongName:1::3.0", nil, nil)
      assert resp.status_code == 200
      assert resp.data == "9.0"
    end

    test "method not found returns 404" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "Nonexistent:9999::true", nil, nil)
      assert resp.status_code == 404
      assert resp.data == "method not found"
    end

    test "malformed colon body returns 400" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "not_a_valid_format", nil, nil)
      assert resp.status_code == 400
      assert resp.content_type == "text/plain"
    end

    test "invalid request JSON returns 400" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "Square:1::not_json", nil, nil)
      assert resp.status_code == 400
    end

    test "handler error with atom status resolves to integer code" do
      svc =
        Service.new()
        |> Service.add_method(
          TestMethods.greet_method(),
          fn _request, _meta -> {:error, Skir.ServiceError.not_found("nope")} end
        )

      body = ~s({"method": "Greet", "request": "x"})
      {resp, _} = Service.handle_request(svc, body, nil, nil)

      assert resp.status_code == 404
      assert resp.data == "nope"
    end
  end

  describe "handle_request — JSON envelope" do
    test "method as string name" do
      svc = build_service()
      body = ~s({"method": "Greet", "request": "World"})
      {resp, _} = Service.handle_request(svc, body, nil, nil)
      assert resp.status_code == 200
      assert resp.data == ~s("Hello, World!")
    end

    test "method as integer number" do
      svc = build_service()
      body = ~s({"method": 2, "request": "Alex"})
      {resp, _} = Service.handle_request(svc, body, nil, nil)
      assert resp.status_code == 200
    end

    test "missing method field returns 400" do
      svc = build_service()
      body = ~s({"request": "x"})
      {resp, _} = Service.handle_request(svc, body, nil, nil)
      assert resp.status_code == 400
    end

    test "invalid JSON returns 400" do
      svc = build_service()
      # truncated
      body = ~s({"method": "Greet", "request":)
      {resp, _} = Service.handle_request(svc, body, nil, nil)
      assert resp.status_code == 400
    end
  end

  describe "handle_request — handler errors" do
    test "ServiceError returns the explicit status code" do
      svc = build_service()
      body = ~s({"method": "Greet", "request": ""})
      {resp, _} = Service.handle_request(svc, body, nil, nil)
      assert resp.status_code == 400
      assert resp.data == "name required"
      assert resp.content_type == "text/plain"
    end

    test "unhandled exception returns 500 with generic message by default" do
      svc = build_service()
      body = ~s({"method": "Crash", "request": "x"})
      {resp, _} = Service.handle_request(svc, body, nil, nil)
      assert resp.status_code == 500
      assert resp.data == "server error"
    end

    test "unhandled exception with expose_internal_errors includes the message" do
      svc = build_service(expose_internal_errors: true)
      body = ~s({"method": "Crash", "request": "x"})
      {resp, _} = Service.handle_request(svc, body, nil, nil)
      assert resp.status_code == 500
      assert resp.data =~ "kaboom"
    end
  end

  describe "handle_request — built-in endpoints" do
    test "empty body serves studio" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "", nil, nil)
      assert resp.status_code == 200
      assert resp.content_type =~ "text/html"
      assert resp.data =~ "skir-studio-app"
    end

    test "'studio' body serves studio" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "studio", nil, nil)
      assert resp.status_code == 200
      assert resp.content_type =~ "text/html"
    end

    test "studio can be disabled" do
      svc = build_service(disable_studio: true)
      {resp, _} = Service.handle_request(svc, "studio", nil, nil)
      assert resp.status_code == 404
    end

    test "'list' returns JSON catalog of methods" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "list", nil, nil)
      assert resp.status_code == 200
      assert resp.content_type == "application/json"
      catalog = JSON.decode!(resp.data)
      assert is_list(catalog["methods"])
      assert length(catalog["methods"]) == 3
    end

    test "list catalog includes method name, number, doc" do
      svc = build_service()
      {resp, _} = Service.handle_request(svc, "list", nil, nil)
      catalog = JSON.decode!(resp.data)

      square = Enum.find(catalog["methods"], &(&1["method"] == "Square"))
      assert square["number"] == 1
      assert is_binary(square["doc"])
    end

    test "list can be disabled" do
      svc = build_service(disable_list: true)
      {resp, _} = Service.handle_request(svc, "list", nil, nil)
      assert resp.status_code == 404
    end
  end

  describe "handle_request — req_meta threading" do
    defmodule MetaMethods do
      use Skir.Methods
      method :echo_meta, 100, request: :string, response: :string
    end

    test "req_meta is passed to the handler" do
      handler = fn _req, meta ->
        send(self(), {:meta_received, meta})
        {:ok, "ok"}
      end

      svc =
        Service.new()
        |> Service.add_method(MetaMethods.echo_meta_method(), handler)

      meta = %{user_id: 42, ip: "10.0.0.1"}

      {_resp, _} =
        Service.handle_request(svc, ~s({"method": "EchoMeta", "request": "x"}), meta, nil)

      assert_received {:meta_received, ^meta}
    end
  end

  describe "handle_request — state pass-through" do
    test "state argument is returned unchanged" do
      svc = build_service()
      state = %{custom: "value"}
      {_resp, new_state} = Service.handle_request(svc, "Square:1::5.0", nil, state)
      assert new_state == state
    end
  end
end
