defmodule Skir.ServiceError do
  @moduledoc """
  A controlled error returned by a method handler, mapped to a non-2xx
  HTTP response.

  The `status` may be an integer (`404`) or an atom (`:not_found`). Atoms
  resolve via `Plug.Conn.Status` when Plug is available, falling back to a
  built-in table of common codes otherwise.

  ## Examples

      {:error, %Skir.ServiceError{status: :not_found, message: "user gone"}}
      {:error, Skir.ServiceError.not_found("user gone")}
      {:error, Skir.ServiceError.new(429, "slow down")}

  In a handler:

      def get_user(%GetUserRequest{id: id}, _meta) do
        case Repo.fetch(id) do
          {:ok, user} -> {:ok, user}
          :error -> {:error, Skir.ServiceError.not_found("no user \#{id}")}
        end
      end
  """

  @enforce_keys [:status, :message]
  defstruct [:status, :message]

  @type status :: 100..599 | atom()

  @type t :: %__MODULE__{
          status: status(),
          message: String.t()
        }

  # Fallback table used only when Plug is not available. Common codes only;
  # exotic codes require Plug or a raw integer.
  @fallback_codes %{
    bad_request: 400,
    unauthorized: 401,
    payment_required: 402,
    forbidden: 403,
    not_found: 404,
    method_not_allowed: 405,
    not_acceptable: 406,
    request_timeout: 408,
    conflict: 409,
    gone: 410,
    unprocessable_entity: 422,
    too_many_requests: 429,
    internal_server_error: 500,
    not_implemented: 501,
    bad_gateway: 502,
    service_unavailable: 503,
    gateway_timeout: 504
  }

  @doc "Build an error with an explicit status (integer or atom) and message."
  @spec new(status(), String.t()) :: t()
  def new(status, message) when is_binary(message),
    do: %__MODULE__{status: status, message: message}

  @doc "400 Bad Request."
  @spec bad_request(String.t()) :: t()
  def bad_request(message \\ "bad request"), do: new(:bad_request, message)

  @doc "401 Unauthorized."
  @spec unauthorized(String.t()) :: t()
  def unauthorized(message \\ "unauthorized"), do: new(:unauthorized, message)

  @doc "403 Forbidden."
  @spec forbidden(String.t()) :: t()
  def forbidden(message \\ "forbidden"), do: new(:forbidden, message)

  @doc "404 Not Found."
  @spec not_found(String.t()) :: t()
  def not_found(message \\ "not found"), do: new(:not_found, message)

  @doc "409 Conflict."
  @spec conflict(String.t()) :: t()
  def conflict(message \\ "conflict"), do: new(:conflict, message)

  @doc "422 Unprocessable Entity."
  @spec unprocessable_entity(String.t()) :: t()
  def unprocessable_entity(message \\ "unprocessable entity"),
    do: new(:unprocessable_entity, message)

  @doc "429 Too Many Requests."
  @spec too_many_requests(String.t()) :: t()
  def too_many_requests(message \\ "too many requests"),
    do: new(:too_many_requests, message)

  @doc """
  Resolves a status (integer or atom) to its HTTP status code integer.

  Integers pass through. Atoms resolve via `Plug.Conn.Status` if Plug is
  loaded, else via a built-in table. Unknown atoms raise `ArgumentError`.
  """
  @spec status_to_code(status()) :: integer()
  def status_to_code(status) when is_integer(status), do: status

  def status_to_code(status) when is_atom(status) do
    if Code.ensure_loaded?(Plug.Conn.Status) and
         function_exported?(Plug.Conn.Status, :code, 1) do
      try do
        Plug.Conn.Status.code(status)
      rescue
        _ -> fallback_code!(status)
      end
    else
      fallback_code!(status)
    end
  end

  defp fallback_code!(status) do
    case Map.fetch(@fallback_codes, status) do
      {:ok, code} ->
        code

      :error ->
        known = @fallback_codes |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

        raise ArgumentError,
              "unknown status atom #{inspect(status)}. Add Plug as a dependency for the " <>
                "full status table, use a known atom (#{known}), or pass a raw integer."
    end
  end
end

defmodule Skir.RawResponse do
  @moduledoc """
  The return value of `Skir.Service.handle_request/4`.

  These fields map directly to an HTTP response. Send them via your
  framework (Plug, Phoenix, raw cowboy, etc.).
  """

  @enforce_keys [:status_code, :content_type, :data]
  defstruct [:status_code, :content_type, :data]

  @type t :: %__MODULE__{
          status_code: non_neg_integer(),
          content_type: String.t(),
          data: iodata()
        }
end

defmodule Skir.Service do
  @moduledoc """
  Server-side SkirRPC dispatch.

  Build a service by registering methods with their handlers, then call
  `handle_request/4` from your HTTP framework's handler.

  ## Example

      service =
        Skir.Service.new()
        |> Skir.Service.add_method(SkirOut.Schema.Methods.square_method(), &MyApp.Calc.square/2)
        |> Skir.Service.add_method(SkirOut.Schema.Methods.sqrt_method(), &MyApp.Calc.sqrt/2)

      # In your HTTP handler:
      {response, _new_state} = Skir.Service.handle_request(service, body, meta, nil)

  ## Handler signature

  Handlers receive the decoded request and a user-defined `req_meta` value
  (auth tokens, request ID, etc.), and return one of:

    * `{:ok, response}` — success
    * `{:error, %Skir.ServiceError{}}` — controlled HTTP error

  ## Built-in endpoints

  In addition to method dispatch, the service responds to two special
  request bodies:

    * `""` or `"studio"` — serves an HTML page that loads Skir Studio
      (a development UI). Disable in production with
      `disable_studio: true`.
    * `"list"` — returns a JSON catalog of registered methods.

  ## Caching

  Building a service rebuilds the registry maps each time. For HTTP servers,
  see `Skir.Service.Cached` for an automatic-caching macro, or store the
  built `%Service{}` in `:persistent_term` yourself.
  """

  alias Skir.Method
  alias Skir.RawResponse
  alias Skir.ServiceError

  @studio_url "https://cdn.jsdelivr.net/npm/skir-studio/dist/skir-studio-standalone.js"

  @enforce_keys [:by_name, :by_number]
  defstruct by_name: %{},
            by_number: %{},
            keep_unrecognized: false,
            disable_studio: false,
            disable_list: false,
            expose_internal_errors: false,
            studio_url: @studio_url

  @type handler :: (term(), term() -> {:ok, term()} | {:error, ServiceError.t()})

  @type t :: %__MODULE__{
          by_name: %{String.t() => {Method.t(), handler()}},
          by_number: %{pos_integer() => {Method.t(), handler()}},
          keep_unrecognized: boolean(),
          disable_studio: boolean(),
          disable_list: boolean(),
          expose_internal_errors: boolean(),
          studio_url: String.t()
        }

  @doc """
  Create a new, empty service.

  ## Options

    * `:keep_unrecognized` — when `true`, unknown request fields are
      preserved when decoding (forward-compat). Default: `false`. Only
      enable for trusted input.
    * `:disable_studio` — disable the `"studio"` HTML endpoint. Default: `false`.
    * `:disable_list` — disable the `"list"` JSON catalog endpoint. Default: `false`.
    * `:expose_internal_errors` — include unhandled exception messages in
      500 responses. Default: `false` (returns just `"server error"`).
    * `:studio_url` — JS bundle URL used by the studio HTML.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      by_name: %{},
      by_number: %{},
      keep_unrecognized: Keyword.get(opts, :keep_unrecognized, false),
      disable_studio: Keyword.get(opts, :disable_studio, false),
      disable_list: Keyword.get(opts, :disable_list, false),
      expose_internal_errors: Keyword.get(opts, :expose_internal_errors, false),
      studio_url: Keyword.get(opts, :studio_url, default_studio_url())
    }
  end

  defp default_studio_url, do: @studio_url

  @doc "Register a method with its handler."
  @spec add_method(t(), Method.t(), handler()) :: t()
  def add_method(%__MODULE__{} = service, %Method{} = method, handler)
      when is_function(handler, 2) do
    entry = {method, handler}

    %{
      service
      | by_name: Map.put(service.by_name, method.name, entry),
        by_number: Map.put(service.by_number, method.number, entry)
    }
  end

  @doc """
  Dispatch an HTTP request body to the appropriate method handler.

  Returns `{%RawResponse{}, new_state}`. The `new_state` is the user-supplied
  `state` unchanged in v1 (handlers don't update state via return value;
  use OTP if you need that).

  ## Body formats accepted

    * `""` or `"studio"` — built-in studio HTML (unless disabled)
    * `"list"` — method catalog JSON (unless disabled)
    * `{"method": <name-or-number>, "request": <value>}` — JSON envelope
    * `name:number:format:request_json` — colon-separated; format is
      `"dense"` or `"readable"`, empty means dense.
  """
  @spec handle_request(t(), binary(), term(), term()) :: {RawResponse.t(), term()}
  def handle_request(%__MODULE__{} = service, body, req_meta, state) do
    trimmed = String.trim(body)

    response =
      cond do
        trimmed in ["", "studio"] -> serve_studio_or_404(service)
        trimmed == "list" -> serve_list_or_404(service)
        String.starts_with?(trimmed, "{") -> handle_json(service, trimmed, req_meta)
        true -> handle_colon(service, trimmed, req_meta)
      end

    {response, state}
  end

  # ---- magic endpoints ----

  defp serve_studio_or_404(%{disable_studio: true}),
    do: %RawResponse{status_code: 404, content_type: "text/plain", data: "not found"}

  defp serve_studio_or_404(service) do
    html =
      "<!DOCTYPE html>" <>
        ~s(<html><head><meta charset="utf-8"><title>Skir Studio</title>) <>
        ~s(<script src=") <>
        service.studio_url <>
        ~s("></script>) <>
        ~s(</head><body><skir-studio-app></skir-studio-app></body></html>)

    %RawResponse{status_code: 200, content_type: "text/html; charset=utf-8", data: html}
  end

  defp serve_list_or_404(%{disable_list: true}),
    do: %RawResponse{status_code: 404, content_type: "text/plain", data: "not found"}

  defp serve_list_or_404(service) do
    methods =
      service.by_name
      |> Map.values()
      |> Enum.sort_by(fn {m, _} -> m.number end)
      |> Enum.map(fn {m, _} ->
        %{"method" => m.name, "number" => m.number, "doc" => m.doc}
      end)

    json = JSON.encode!(%{"methods" => methods})
    %RawResponse{status_code: 200, content_type: "application/json", data: json}
  end

  # ---- request parsing ----

  defp handle_json(service, body, req_meta) do
    case parse_json_envelope(body) do
      {:ok, method_id, request_value} ->
        invoke(service, method_id, request_value, readable: true, req_meta: req_meta)

      {:error, message} ->
        %RawResponse{status_code: 400, content_type: "text/plain", data: message}
    end
  end

  defp handle_colon(service, body, req_meta) do
    case parse_colon_envelope(body) do
      {:ok, method_id, readable, request_value} ->
        invoke(service, method_id, request_value, readable: readable, req_meta: req_meta)

      {:error, message} ->
        %RawResponse{status_code: 400, content_type: "text/plain", data: message}
    end
  end

  defp parse_json_envelope(body) do
    try do
      case JSON.decode!(body) do
        %{"method" => method, "request" => request} ->
          method_id =
            cond do
              is_binary(method) -> {:name, method}
              is_integer(method) -> {:number, method}
              true -> :invalid
            end

          case method_id do
            :invalid -> {:error, "'method' field must be string or integer"}
            mid -> {:ok, mid, request}
          end

        _ ->
          {:error, "JSON body must be an object with 'method' and 'request' fields"}
      end
    rescue
      _ -> {:error, "invalid JSON body"}
    end
  end

  defp parse_colon_envelope(body) do
    case String.split(body, ":", parts: 4) do
      [name, number_str, format, request_json] ->
        method_id =
          case Integer.parse(number_str) do
            {n, ""} when n > 0 -> {:number, n}
            _ -> {:name, name}
          end

        readable = format == "readable"

        try do
          parsed = JSON.decode!(request_json)
          {:ok, method_id, readable, parsed}
        rescue
          _ -> {:error, "invalid request JSON"}
        end

      _ ->
        {:error, "invalid request format; expected name:number:format:requestJson"}
    end
  end

  # ---- invocation ----

  defp invoke(service, method_id, request_dynamic, readable: readable, req_meta: req_meta) do
    case lookup(service, method_id) do
      :error ->
        %RawResponse{status_code: 404, content_type: "text/plain", data: "method not found"}

      {:ok, {method, handler}} ->
        run_method(service, method, handler, request_dynamic, readable, req_meta)
    end
  end

  defp lookup(service, {:name, name}), do: Map.fetch(service.by_name, name)
  defp lookup(service, {:number, n}), do: Map.fetch(service.by_number, n)

  defp run_method(service, method, handler, request_dynamic, readable, req_meta) do
    request_value =
      try do
        method.request_serializer.type_adapter.decode_json.(request_dynamic, [])
      rescue
        e in Skir.DecodeError ->
          throw({:bad_request, "bad request: " <> Exception.message(e)})
      end

    response =
      try do
        handler.(request_value, req_meta)
      rescue
        e ->
          message =
            if service.expose_internal_errors,
              do: "server error: " <> Exception.message(e),
              else: "server error"

          throw({:internal, message})
      end

    case response do
      {:ok, value} ->
        flavor = if readable, do: :readable, else: :dense
        json = Skir.Serializer.encode_json(method.response_serializer, value, flavor)
        %RawResponse{status_code: 200, content_type: "application/json", data: json}

      {:error, %ServiceError{status: status, message: message}} ->
        %RawResponse{
          status_code: Skir.ServiceError.status_to_code(status),
          content_type: "text/plain",
          data: message
        }

      other ->
        message = "handler returned unexpected value: #{inspect(other)}"

        %RawResponse{
          status_code: 500,
          content_type: "text/plain",
          data: message
        }
    end
  catch
    {:bad_request, msg} ->
      %RawResponse{status_code: 400, content_type: "text/plain", data: msg}

    {:internal, msg} ->
      %RawResponse{status_code: 500, content_type: "text/plain", data: msg}
  end

  # ===========================================================================
  # Declarative DSL (compile-time, gRPC-style convention-by-name)
  # ===========================================================================

  @doc """
  Define a service declaratively. Handlers are plain functions named after
  the methods they implement.

      defmodule MyApp.RpcService do
        use Skir.Service, methods: SkirOut.Schema.Methods

        @impl true
        def square(request, _meta), do: {:ok, request * request}

        @impl true
        def get_user(%SkirOut.GetUserRequest{id: id}, _meta) do
          case MyApp.Repo.fetch_user(id) do
            {:ok, user} -> {:ok, user}
            :error -> {:error, Skir.ServiceError.not_found("no user")}
          end
        end
      end

      plug Skir.Plug, service: &MyApp.RpcService.service/0

  For each method `:foo` declared in the `:methods` module, define a
  function `foo/2` taking `(request, req_meta)` and returning
  `{:ok, response}` or `{:error, %Skir.ServiceError{}}`. A missing handler
  is a compile error.

  Options besides `:methods` pass through to `new/1`:

      use Skir.Service, methods: SkirOut.Schema.Methods, disable_studio: true

  For anonymous handlers or dynamic services (multi-tenant, per-request
  config, tests), use the runtime API: `new/1` + `add_method/3`.
  """
  defmacro __using__(opts) do
    methods_mod =
      Keyword.get(opts, :methods) ||
        raise ArgumentError, "use Skir.Service requires the :methods option"

    service_opts = Keyword.delete(opts, :methods)

    quote do
      @__skir_methods_module__ unquote(methods_mod)
      @__skir_service_opts__ unquote(service_opts)
      @before_compile Skir.Service
    end
  end

  defmacro __before_compile__(env) do
    methods_mod = Module.get_attribute(env.module, :__skir_methods_module__)
    methods = methods_mod.__skir_methods__()

    callbacks = Skir.Service.__callback_asts__(methods)

    missing = Enum.reject(methods, fn m -> Module.defines?(env.module, {m.name, 2}) end)

    if missing != [] do
      details =
        Enum.map_join(missing, "\n", fn m ->
          "  * #{m.name}/2 (method \"#{Macro.camelize(Atom.to_string(m.name))}\", number #{m.number})"
        end)

      raise CompileError,
        description:
          "#{inspect(env.module)}: missing handler functions for these methods:\n" <>
            details <>
            "\n\nDefine each as `def <name>(request, meta)` returning " <>
            "`{:ok, response}` or `{:error, %Skir.ServiceError{}}`."
    end

    add_calls =
      Enum.map(methods, fn m ->
        method_fn = String.to_atom("#{m.name}_method")

        quote do
          acc =
            Skir.Service.add_method(
              acc,
              unquote(methods_mod).unquote(method_fn)(),
              Function.capture(__MODULE__, unquote(m.name), 2)
            )
        end
      end)

    quote do
      @behaviour __MODULE__
      unquote_splicing(callbacks)

      @doc "Returns the built (and cached) `%Skir.Service{}` for this module."
      @spec service() :: Skir.Service.t()
      def service do
        key = {__MODULE__, :__skir_service__}

        case :persistent_term.get(key, :__not_built__) do
          :__not_built__ ->
            built = build_service()
            :persistent_term.put(key, built)
            built

          built ->
            built
        end
      end

      defp build_service do
        acc = Skir.Service.new(@__skir_service_opts__)
        unquote_splicing(add_calls)
        acc
      end
    end
  end

  @doc false
  # Generates precise @callback ASTs from each method's request/response types.
  def __callback_asts__(methods) do
    Enum.map(methods, fn m ->
      request_spec = Skir.Struct.TypeGen.type_spec_for(m.request)
      response_spec = Skir.Struct.TypeGen.type_spec_for(m.response)

      quote do
        @callback unquote(m.name)(unquote(request_spec), req_meta :: term()) ::
                    {:ok, unquote(response_spec)} | {:error, Skir.ServiceError.t()}
      end
    end)
  end
end
