defmodule Skir.RpcError do
  @moduledoc """
  Error returned by `Skir.ServiceClient.invoke/3` when the request fails
  at the transport layer or the server returns a non-2xx response.

    * `status_code: 0` — transport-level error (DNS, connection refused,
      timeout). The `message` describes the failure.
    * `status_code: 4xx/5xx` — HTTP error response from the server. The
      `message` is the server's response body if it was `text/plain`,
      otherwise empty.
  """

  @enforce_keys [:status_code, :message]
  defstruct [:status_code, :message]

  @type t :: %__MODULE__{
          status_code: non_neg_integer(),
          message: String.t()
        }
end

defmodule Skir.ServiceClient do
  @moduledoc """
  Client for invoking remote SkirRPC methods.

  ## Example

      client = Skir.ServiceClient.new("http://localhost:8000/api")
      {:ok, 25.0} = Skir.ServiceClient.invoke(client, SkirOut.Schema.Methods.square(), 5.0)

  ## Headers

  Add default headers (sent with every request) via
  `with_default_header/3`:

      client =
        Skir.ServiceClient.new("http://localhost:8000/api")
        |> Skir.ServiceClient.with_default_header("Authorization", "Bearer ...")

  ## HTTP backend

  By default the client uses OTP's `:httpc`. To use a different HTTP
  library (Finch, Req, Mint, etc.), pass `send_fn:` to `new/2`:

      Skir.ServiceClient.new("http://...", send_fn: &my_http_send/1)

  The `send_fn` receives a map with `:method`, `:url`, `:headers`, `:body`
  and must return `{:ok, %{status: integer, headers: list, body: binary}}`
  or `{:error, reason}`.
  """

  alias Skir.Method
  alias Skir.RpcError
  alias Skir.Serializer

  @enforce_keys [:service_url]
  defstruct [:service_url, headers: [], send_fn: nil]

  @type t :: %__MODULE__{
          service_url: String.t(),
          headers: [{String.t(), String.t()}],
          send_fn: function() | nil
        }

  @doc """
  Build a client for the given service URL.

  ## Options

    * `:send_fn` — custom HTTP request function. Defaults to one backed
      by `:httpc`.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(service_url, opts \\ []) do
    if String.contains?(service_url, "?") do
      raise ArgumentError, "service URL must not contain a query string"
    end

    %__MODULE__{
      service_url: service_url,
      headers: [],
      send_fn: Keyword.get(opts, :send_fn, &default_send/1)
    }
  end

  @doc "Add a header sent with every invocation."
  @spec with_default_header(t(), String.t(), String.t()) :: t()
  def with_default_header(%__MODULE__{} = client, key, value) do
    %{client | headers: client.headers ++ [{key, value}]}
  end

  @doc """
  Invoke a method on the remote service.

  Returns `{:ok, response}` on success, or `{:error, %RpcError{}}` on
  transport failure or non-2xx response.
  """
  @spec invoke(t(), Method.t(), term()) :: {:ok, term()} | {:error, RpcError.t()}
  def invoke(%__MODULE__{} = client, %Method{} = method, request_value) do
    request_json = Serializer.encode_json(method.request_serializer, request_value, :dense)
    wire_body = method.name <> ":" <> Integer.to_string(method.number) <> "::" <> request_json

    request = %{
      method: :post,
      url: client.service_url,
      headers: [{"content-type", "text/plain; charset=utf-8"} | client.headers],
      body: wire_body
    }

    case client.send_fn.(request) do
      {:error, reason} ->
        {:error, %RpcError{status_code: 0, message: "network error: #{inspect(reason)}"}}

      {:ok, %{status: status} = response} when status >= 200 and status < 300 ->
        decode_response(method, response.body)

      {:ok, %{status: status} = response} ->
        message =
          if text_plain?(response.headers),
            do: response.body,
            else: ""

        {:error, %RpcError{status_code: status, message: message}}
    end
  end

  defp decode_response(method, body) when is_binary(body) do
    try do
      value = Serializer.decode_json!(method.response_serializer, body)
      {:ok, value}
    rescue
      e ->
        {:error,
         %RpcError{status_code: 0, message: "failed to decode response: " <> Exception.message(e)}}
    end
  end

  defp text_plain?(headers) do
    Enum.any?(headers, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        String.downcase(k) == "content-type" and
          String.contains?(String.downcase(v), "text/plain")

      _ ->
        false
    end)
  end

  # Default HTTP backend using :httpc.
  defp default_send(%{method: :post, url: url, headers: headers, body: body}) do
    :inets.start()
    :ssl.start()

    httpc_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    content_type =
      Enum.find_value(headers, "text/plain; charset=utf-8", fn
        {k, v} when is_binary(k) -> if String.downcase(k) == "content-type", do: v
        _ -> nil
      end)

    httpc_request =
      {String.to_charlist(url), httpc_headers, String.to_charlist(content_type), body}

    case :httpc.request(:post, httpc_request, [], []) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} ->
        normalized_headers =
          Enum.map(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end)

        {:ok, %{status: status, headers: normalized_headers, body: to_string(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
