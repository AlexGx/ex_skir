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
        `%Skir.Service{}` (e.g. `&MyModule.service/0` from
        `use Skir.Service`). Called once in `init/1`; the result is held
        in plug state.

      * `:meta_fn` — optional. Function `(Plug.Conn -> req_meta)` that
        builds your `RequestMeta` value from the connection (auth
        headers, client IP, etc.). Defaults to `fn _ -> nil end`.

    ## Initialization

    The plug builds the service in `init/1` and holds it in plug state.
    Because a service holds function references (handlers, codecs), `init`
    must run at runtime, not compile time:

      * `forward "/api", to: Skir.Plug, init_opts: [service: ...]` — init
        runs at runtime; works directly.
      * `plug Skir.Plug, service: ...` in a `Plug.Builder` or Phoenix
        pipeline — add `init_mode: :runtime` to that plug. Otherwise init
        runs at compile time and cannot embed the service's function
        references.
    """

    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts) do
      service_fn = Keyword.fetch!(opts, :service)
      meta_fn = Keyword.get(opts, :meta_fn, fn _ -> nil end)
      # Build the service once at init and hold it in plug state. Assembly is
      # cheap; doing it here avoids rebuilding per request. The service holds
      # function references, so init must run at runtime (see moduledoc).
      %{service: service_fn.(), meta_fn: meta_fn}
    end

    @impl true
    def call(conn, %{service: service, meta_fn: meta_fn}) do
      {conn, body} = read_request_body(conn)
      meta = meta_fn.(conn)

      {response, _state} = Skir.Service.handle_request(service, body, meta, nil)

      conn
      |> put_resp_header("content-type", response.content_type)
      |> send_resp(response.status_code, response.data)
      |> halt()
    end

    defp read_request_body(%Plug.Conn{method: "POST"} = conn) do
      read_full_body(conn, [])
    end

    defp read_request_body(%Plug.Conn{method: "GET"} = conn) do
      body = conn.query_string |> URI.decode()
      {conn, body}
    end

    defp read_request_body(conn), do: {conn, ""}

    defp read_full_body(conn, acc) do
      case read_body(conn) do
        {:ok, chunk, conn} ->
          {conn, IO.iodata_to_binary([acc, chunk])}

        {:more, chunk, conn} ->
          read_full_body(conn, [acc, chunk])

        {:error, reason} ->
          raise "failed to read body: #{inspect(reason)}"
      end
    end
  end
end
