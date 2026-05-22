if Code.ensure_loaded?(Plug.Conn) do
  defmodule Skir.Plug do
    @moduledoc """
    Plug that dispatches HTTP requests to a `Skir.Service`.

    Works with any Plug-based stack, including Phoenix.

    ## Example with Plug.Router

        defmodule MyApp.Router do
          use Plug.Router

          plug :match
          plug :dispatch

          forward "/api", to: Skir.Plug,
            init_opts: [service: &MyApp.RpcService.service/0]
        end

    ## Example with Phoenix

        # In your Phoenix endpoint or a pipeline:
        plug Skir.Plug,
          service: &MyApp.RpcService.service/0,
          meta_fn: &MyApp.Auth.extract/1

    ## Options

      * `:service` — required. Zero-arity function returning a
        `%Skir.Service{}`. If you use `Skir.Service.Cached`,
        pass `&MyModule.service/0`.

      * `:meta_fn` — optional. Function `(Plug.Conn -> req_meta)` that
        builds your `RequestMeta` value from the connection (auth
        headers, client IP, etc.). Defaults to `fn _ -> nil end`.
    """

    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts) do
      service_fn = Keyword.fetch!(opts, :service)
      meta_fn = Keyword.get(opts, :meta_fn, fn _ -> nil end)
      %{service_fn: service_fn, meta_fn: meta_fn}
    end

    @impl true
    def call(conn, %{service_fn: service_fn, meta_fn: meta_fn}) do
      {conn, body} = read_request_body(conn)
      service = service_fn.()
      meta = meta_fn.(conn)

      {response, _state} = Skir.Service.handle_request(service, body, meta, nil)

      conn
      |> put_resp_content_type(response.content_type)
      |> send_resp(response.status_code, response.data)
      |> halt()
    end

    defp read_request_body(%Plug.Conn{method: "POST"} = conn) do
      case read_body(conn) do
        {:ok, body, conn} -> {conn, body}
        {:more, _, _} -> raise "request body too large"
        {:error, reason} -> raise "failed to read body: #{inspect(reason)}"
      end
    end

    defp read_request_body(%Plug.Conn{method: "GET"} = conn) do
      body = conn.query_string |> URI.decode()
      {conn, body}
    end

    defp read_request_body(conn), do: {conn, ""}
  end
end
