defmodule Skir.ServiceClientTest do
  use ExUnit.Case, async: true

  alias Skir.{ServiceClient, RpcError, Service, ServiceError}

  defmodule Methods do
    use Skir.Methods

    method :double, 1, request: :int32, response: :int32
    method :concat, 2, request: :string, response: :string
  end

  defp build_service do
    Service.new()
    |> Service.add_method(Methods.double_method(), fn n, _ -> {:ok, n * 2} end)
    |> Service.add_method(Methods.concat_method(), fn s, _ -> {:ok, s <> s} end)
  end

  defp in_process_send(service) do
    fn req ->
      {resp, _} = Service.handle_request(service, req.body, nil, nil)

      {:ok,
       %{
         status: resp.status_code,
         headers: [{"content-type", resp.content_type}],
         body: resp.data
       }}
    end
  end

  describe "new/2" do
    test "creates a client with the given URL" do
      client = ServiceClient.new("http://example.com/api")
      assert client.service_url == "http://example.com/api"
      assert client.headers == []
    end

    test "raises on query string in URL" do
      assert_raise ArgumentError, ~r/must not contain a query string/, fn ->
        ServiceClient.new("http://example.com/api?x=1")
      end
    end

    test "accepts custom send_fn" do
      send_fn = fn _ -> {:ok, %{status: 200, headers: [], body: "0"}} end
      client = ServiceClient.new("http://x", send_fn: send_fn)
      assert client.send_fn == send_fn
    end
  end

  describe "with_default_header/3" do
    test "appends header to client" do
      client =
        ServiceClient.new("http://x")
        |> ServiceClient.with_default_header("X-Test", "v1")

      assert client.headers == [{"X-Test", "v1"}]
    end

    test "chained calls append in order" do
      client =
        ServiceClient.new("http://x")
        |> ServiceClient.with_default_header("X-One", "1")
        |> ServiceClient.with_default_header("X-Two", "2")

      assert client.headers == [{"X-One", "1"}, {"X-Two", "2"}]
    end
  end

  describe "invoke/3 — wire body" do
    test "builds colon format body with empty middle field (dense)" do
      received = :ets.new(:received, [:public, :set])
      :ets.insert(received, {:body, nil})

      send_fn = fn req ->
        :ets.insert(received, {:body, req.body})
        {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: "0"}}
      end

      client = ServiceClient.new("http://x", send_fn: send_fn)
      ServiceClient.invoke(client, Methods.double_method(), 7)

      [{:body, body}] = :ets.lookup(received, :body)
      assert body == "Double:1::7"

      :ets.delete(received)
    end

    test "POST method with text/plain content-type" do
      received = :ets.new(:received, [:public, :set])
      :ets.insert(received, {:request, nil})

      send_fn = fn req ->
        :ets.insert(received, {:request, req})
        {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: "0"}}
      end

      client = ServiceClient.new("http://x", send_fn: send_fn)
      ServiceClient.invoke(client, Methods.double_method(), 1)

      [{:request, req}] = :ets.lookup(received, :request)
      assert req.method == :post

      assert Enum.any?(req.headers, fn {k, v} ->
               String.downcase(k) == "content-type" and v =~ "text/plain"
             end)

      :ets.delete(received)
    end

    test "default headers are included in request" do
      received = :ets.new(:received, [:public, :set])
      :ets.insert(received, {:headers, []})

      send_fn = fn req ->
        :ets.insert(received, {:headers, req.headers})
        {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: "0"}}
      end

      client =
        ServiceClient.new("http://x", send_fn: send_fn)
        |> ServiceClient.with_default_header("Authorization", "Bearer xyz")

      ServiceClient.invoke(client, Methods.double_method(), 1)

      [{:headers, headers}] = :ets.lookup(received, :headers)
      assert Enum.any?(headers, fn {k, v} -> k == "Authorization" and v == "Bearer xyz" end)

      :ets.delete(received)
    end
  end

  describe "invoke/3 — round-trip with service" do
    test "successful response decodes correctly" do
      svc = build_service()
      client = ServiceClient.new("http://x", send_fn: in_process_send(svc))

      assert {:ok, 14} = ServiceClient.invoke(client, Methods.double_method(), 7)
    end

    test "string round-trip" do
      svc = build_service()
      client = ServiceClient.new("http://x", send_fn: in_process_send(svc))

      assert {:ok, "abab"} = ServiceClient.invoke(client, Methods.concat_method(), "ab")
    end
  end

  describe "invoke/3 — error handling" do
    test "non-2xx returns RpcError with status code" do
      send_fn = fn _req ->
        {:ok,
         %{
           status: 404,
           headers: [{"content-type", "text/plain"}],
           body: "method not found"
         }}
      end

      client = ServiceClient.new("http://x", send_fn: send_fn)

      assert {:error, %RpcError{status_code: 404, message: "method not found"}} =
               ServiceClient.invoke(client, Methods.double_method(), 1)
    end

    test "non-text/plain error response has empty message" do
      send_fn = fn _req ->
        {:ok,
         %{
           status: 500,
           headers: [{"content-type", "application/json"}],
           body: ~s({"error":"x"})
         }}
      end

      client = ServiceClient.new("http://x", send_fn: send_fn)

      assert {:error, %RpcError{status_code: 500, message: ""}} =
               ServiceClient.invoke(client, Methods.double_method(), 1)
    end

    test "transport error returns status_code 0" do
      send_fn = fn _ -> {:error, :timeout} end
      client = ServiceClient.new("http://x", send_fn: send_fn)

      assert {:error, %RpcError{status_code: 0}} =
               ServiceClient.invoke(client, Methods.double_method(), 1)
    end

    test "service-level ServiceError flows through to client as RpcError" do
      svc =
        Service.new()
        |> Service.add_method(Methods.double_method(), fn _, _ ->
          {:error, %ServiceError{status: 403, message: "forbidden"}}
        end)

      client = ServiceClient.new("http://x", send_fn: in_process_send(svc))

      assert {:error, %RpcError{status_code: 403, message: "forbidden"}} =
               ServiceClient.invoke(client, Methods.double_method(), 1)
    end
  end
end
