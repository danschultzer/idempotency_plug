defmodule IdempotencyPlug do
  @moduledoc """
  Plug that handles `Idempotency-Key` HTTP headers.

  A single `Idempotency-Key` HTTP header is required for POST and PATCH requests.

  Handling of requests is based on
  https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/

  ## Idempotency Key

  The value of the `Idempotency-Key` HTTP header is combined with the URI path
  and hashed with sha256 to produce a request ID. The first response for that
  request ID is stored and replayed on subsequent requests.

  A separate sha256 hash of the request payload is stored alongside the
  request ID and used to detect reuse of the same `Idempotency-Key` with a
  different payload.

  ## Error handling

  Status codes are returned per
  [section 2.7](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/#section-2.7)
  of the IETF draft:

    * `400 Bad Request` - when `Idempotency-Key` is missing
      (`IdempotencyPlug.NoHeadersError`) or supplied more than once
      (`IdempotencyPlug.MultipleHeadersError`).

    * `409 Conflict` - when a request with the same `Idempotency-Key` is still
      being processed (`IdempotencyPlug.ConcurrentRequestError`).

    * `422 Unprocessable Content` - when the `Idempotency-Key` is reused with
      a different payload or URI
      (`IdempotencyPlug.RequestPayloadFingerprintMismatchError`).

  Additionally `500 Internal Server Error` is returned when the first attempt
  was unexpectedly interrupted and never cached
  (`IdempotencyPlug.HaltedResponseError`).

  By default these errors are raised and rendered by the `Plug.Exception`
  protocol. Section 2.7 suggests `application/problem+json` response bodies
  ([RFC 9457](https://www.rfc-editor.org/info/rfc9457/)). The `:with` option
  can be used to format responses that way, see the example below.

  ## Cached responses

  Cached responses use the original status, body, and headers. Any response
  headers already set on the conn by upstream plugs are dropped. An `Expires`
  header is added on top. See `IdempotencyPlug.RequestTracker` for more on
  expiration.

  ## Authenticated requests

  When authenticating users, scope the key to the user via the
  `:idempotency_key` option to prevent cross-user cache hits:

      plug IdempotencyPlug,
        tracker: MyAppWeb.RequestTracker,
        idempotency_key: {__MODULE__, :scope_idempotency_key}

      def scope_idempotency_key(conn, key), do: {conn.assigns.current_user.id, key}

  ## `Idempotent-Replayed` header

  Stripe uses an `Idempotent-Replayed` response header to indicate that a
  response is a replay of a cached response. This can be added to cached
  responses with the `:cached_headers` option:

      plug IdempotencyPlug,
        tracker: MyAppWeb.RequestTracker,
        cached_headers: [{"idempotent-replayed", "true"}]

  ## Options

    * `:tracker` - `t:GenServer.server/0` reference for the
      `IdempotencyPlug.RequestTracker` GenServer, required.

    * `:idempotency_key` - should be a MFA tuple callback to process
      idempotency key. Defaults to `{#{__MODULE__}, :idempotency_key}`.

    * `:request_payload` - should be a MFA tuple callback to shape request
      payload. Defaults to `{#{__MODULE__}, :request_payload}`.

    * `:hash` - should be a MFA tuple callback to hash an Erlang term. The
      callback receives `(type, value)` where `type` is `:idempotency_key`
      or `:request_payload`. Defaults to `{#{__MODULE__}, :sha256_hash}`.

    * `:with` - should be one of `:exception` or MFA tuple. Defaults to
      `:exception`.
      - `:exception` - raises an error.
      - `{mod, fun, args}` - calls the MFA to process the conn with error, the
        connection MUST be halted.

    * `:cached_headers` - a list of response `{name, value}` tuple headers to
      add on top of the cached response.

  ## Telemetry events

  The following events are emitted by the Plug:

    * `[:idempotency_plug, :track, :start]` - dispatched before tracking a request
      * Measurement: `%{monotonic_time: integer(), system_time: integer()}`
      * Metadata: `%{telemetry_span_context: term(), conn: Plug.Conn.t(), tracker: GenServer.server(), idempotency_key: binary()}`

    * `[:idempotency_plug, :track, :exception]` - dispatched on exceptions during request tracking
      * Measurement: `%{monotonic_time: integer(), duration: integer()}`
      * Metadata: `%{telemetry_span_context: term(), conn: Plug.Conn.t(), tracker: GenServer.server(), idempotency_key: binary(), kind: :throw | :error | :exit, reason: term(), stacktrace: list()}`

    * `[:idempotency_plug, :track, :stop]` - dispatched after successfully tracking a request
      * Measurement: `%{monotonic_time: integer(), duration: integer()}`
      * Metadata: `%{telemetry_span_context: term(), conn: Plug.Conn.t(), tracker: GenServer.server(), idempotency_key: binary()}`

  ## Examples

      plug IdempotencyPlug,
        tracker: IdempotencyPlug.RequestTracker,
        idempotency_key: {__MODULE__, :scope_idempotency_key},
        request_payload: {__MODULE__, :limit_request_payload},
        hash: {__MODULE__, :sha512_hash},
        with: {__MODULE__, :handle_error},
        cached_headers: [{"idempotent-replayed", "true"}]

      def scope_idempotency_key(conn, key) do
        {conn.assigns.user.id, key}
      end

      def limit_request_payload(conn) do
        Map.drop(conn.params, ["value"])
      end

      def sha512_hash(_type, value) do
        :sha512
        |> :crypto.hash(:erlang.term_to_binary(value))
        |> Base.encode16()
        |> String.downcase()
      end

      def handle_error(conn, error) do
        conn
        |> put_status(error.plug_status)
        |> put_resp_content_type("application/problem+json")
        |> json(%{
          type: "https://example.com/errors/idempotency",
          title: error.message,
          status: error.plug_status
        })
        |> halt()
      end
  """
  @behaviour Plug

  alias IdempotencyPlug.RequestTracker
  alias Plug.Conn

  defmodule NoHeadersError do
    @moduledoc """
    There's no Idempotency-Key request headers.
    """

    defexception message:
                   "No idempotency key found. You need to set the `Idempotency-Key` header for all POST and PATCH requests: 'Idempotency-Key: KEY'",
                 plug_status: :bad_request
  end

  defmodule MultipleHeadersError do
    @moduledoc """
    There are multiple Idempotency-Key request headers.
    """

    defexception message: "Only one `Idempotency-Key` header can be sent",
                 plug_status: :bad_request
  end

  defmodule ConcurrentRequestError do
    @moduledoc """
    There's another request currently being processed for this ID.
    """

    defexception message:
                   "A request with the same `Idempotency-Key` is currently being processed",
                 plug_status: :conflict
  end

  defmodule RequestPayloadFingerprintMismatchError do
    @moduledoc """
    The fingerprint for the request payload doesn't match the cached response.
    """

    defexception [
      :fingerprint,
      message: "This `Idempotency-Key` can't be reused with a different payload or URI",
      plug_status: :unprocessable_entity
    ]
  end

  defmodule HaltedResponseError do
    @moduledoc """
    The cached response process didn't terminate correctly.
    """

    defexception [
      :reason,
      message:
        "The original request was interrupted and can't be recovered as it's in an unknown state",
      plug_status: :internal_server_error
    ]
  end

  defimpl Plug.Exception,
    for: [
      NoHeadersError,
      MultipleHeadersError,
      ConcurrentRequestError,
      RequestPayloadFingerprintMismatchError,
      HaltedResponseError
    ] do
    def status(%{plug_status: status}), do: Plug.Conn.Status.code(status)
    def actions(_), do: []
  end

  @doc false
  @impl true
  def init(options) do
    options
    |> verify_tracker!()
    |> verify_with!()
    |> verify_mfa_tuple!(:idempotency_key, {__MODULE__, :idempotency_key})
    |> verify_mfa_tuple!(:request_payload, {__MODULE__, :request_payload})
    |> verify_mfa_tuple!(:hash, {__MODULE__, :sha256_hash})
    |> verify_cached_headers!()
  end

  defp verify_tracker!(options) do
    do_verify_tracker!(Keyword.get(options, :tracker))

    options
  end

  defp do_verify_tracker!(pid) when is_pid(pid), do: :ok
  defp do_verify_tracker!(atom) when is_atom(atom) and not is_nil(atom), do: :ok
  defp do_verify_tracker!({atom, node}) when is_atom(atom) and is_atom(node), do: :ok
  defp do_verify_tracker!({:global, _term}), do: :ok
  defp do_verify_tracker!({:via, _module, _term}), do: :ok

  defp do_verify_tracker!(other) do
    raise ArgumentError,
          "option :tracker must be a GenServer.server/0 type, got: #{inspect(other)}"
  end

  defp verify_with!(options) do
    case Keyword.get(options, :with, :exception) do
      :exception ->
        Keyword.put(options, :with, :exception)

      {mod, fun} ->
        Keyword.put(options, :with, {mod, fun, []})

      {mod, fun, args} ->
        Keyword.put(options, :with, {mod, fun, args})

      other ->
        raise ArgumentError,
              "option :with should be one of :exception or MFA tuple, got: #{inspect(other)}"
    end
  end

  defp verify_mfa_tuple!(options, key, default) do
    {mod, fun, args} =
      case Keyword.get(options, key, default) do
        {mod, fun} ->
          {mod, fun, []}

        {mod, fun, args} ->
          {mod, fun, args}

        other ->
          raise ArgumentError,
                "option #{inspect(key)} must be a MFA tuple, got: #{inspect(other)}"
      end

    Keyword.put(options, key, {mod, fun, args})
  end

  defp verify_cached_headers!(options) do
    options
    |> Keyword.get(:cached_headers, [])
    |> case do
      list when is_list(list) ->
        list

      other ->
        raise ArgumentError,
              "option :cached_headers must be a list of header tuples, got: #{inspect(other)}"
    end
    |> Enum.each(fn
      {key, value} when is_binary(key) and is_binary(value) ->
        :ok

      other ->
        raise ArgumentError,
              "option :cached_headers must be a list of {name, value} header tuples, got: #{inspect(other)}"
    end)

    options
  end

  @doc false
  @impl true
  def call(%{method: method} = conn, options) when method in ~w(POST PATCH) do
    case Conn.get_req_header(conn, "idempotency-key") do
      [key] -> handle_idempotent_request(conn, key, options)
      [_ | _] -> raise MultipleHeadersError
      [] -> raise NoHeadersError
    end
  rescue
    error in [
      NoHeadersError,
      MultipleHeadersError,
      ConcurrentRequestError,
      RequestPayloadFingerprintMismatchError,
      HaltedResponseError
    ] ->
      case Keyword.fetch!(options, :with) do
        :exception ->
          reraise error, __STACKTRACE__

        {mod, fun, args} ->
          ensure_is_halted!(conn, error, mod, fun, args)
      end
  end

  def call(conn, _options), do: conn

  defp handle_idempotent_request(conn, key, options) do
    tracker = Keyword.fetch!(options, :tracker)

    idempotency_key_hash = hash_idempotency_key(conn, key, options)
    request_payload_hash = hash_request_payload(conn, options)

    metadata =
      %{
        conn: conn,
        tracker: tracker,
        idempotency_key: key
      }

    :telemetry.span([:idempotency_plug, :track], metadata, fn ->
      case RequestTracker.track(tracker, idempotency_key_hash, request_payload_hash) do
        {:processing, _node_caller, _expires} ->
          raise ConcurrentRequestError

        {:mismatch, {:fingerprint, fingerprint}, _expires} ->
          raise RequestPayloadFingerprintMismatchError, fingerprint: fingerprint

        {:cache, {:halted, reason}, _expires} ->
          raise HaltedResponseError, reason: reason

        {:cache, {:ok, response}, expires} ->
          conn =
            conn
            |> put_resp(response, options)
            |> put_expires_header(expires)
            |> Conn.halt()

          {conn, %{metadata | conn: conn}}

        {:init, idempotency_key, _expires} ->
          conn = update_response_before_send(conn, idempotency_key, options)

          {conn, %{metadata | conn: conn}}

        {:error, error} ->
          raise "failed to track request, got: #{inspect(error)}"
      end
    end)
  end

  @doc """
  Default `:idempotency_key` callback.

  Returns the key unchanged.
  """
  @spec idempotency_key(Conn.t(), term()) :: term()
  def idempotency_key(_conn, key), do: key

  defp hash_idempotency_key(conn, key, options) do
    key = {key, conn.path_info}
    {mod, fun, args} = Keyword.fetch!(options, :idempotency_key)
    processed_key = apply(mod, fun, [conn, key | args])

    hash(:idempotency_key, processed_key, options)
  end

  @doc """
  Default `:request_payload` callback.

  Returns request params as a sorted list so the resulting hash is
  deterministic.
  """
  @spec request_payload(Conn.t()) :: [{binary(), term()}]
  def request_payload(conn) do
    conn.params
    |> Map.to_list()
    |> Enum.sort()
  end

  defp hash_request_payload(conn, options) do
    {mod, fun, args} = Keyword.fetch!(options, :request_payload)
    payload = apply(mod, fun, [conn | args])

    hash(:request_payload, payload, options)
  end

  defp hash(type, value, options) do
    {mod, fun, args} = Keyword.fetch!(options, :hash)

    apply(mod, fun, [type, value | args])
  end

  @doc """
  Default `:hash` callback.

  Returns a hex encoded sha256 hash of `value`. `type` is ignored.
  """
  @spec sha256_hash(:idempotency_key | :request_payload, term()) :: binary()
  def sha256_hash(_type, value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16()
    |> String.downcase()
  end

  defp update_response_before_send(conn, key, options) do
    tracker = Keyword.fetch!(options, :tracker)

    Conn.register_before_send(conn, fn conn ->
      case RequestTracker.put_response(tracker, key, conn_to_response(conn)) do
        {:ok, expires} -> put_expires_header(conn, expires)
        {:error, error} -> raise "failed to put response in cache store, got: #{inspect(error)}"
      end
    end)
  end

  defp conn_to_response(conn) do
    Map.take(conn, [:resp_body, :resp_headers, :status])
  end

  defp put_resp(conn, %{resp_body: body, resp_headers: headers, status: status}, options) do
    headers =
      options
      |> Keyword.get(:cached_headers, [])
      |> Enum.reduce(headers, fn {key, value}, headers ->
        List.keystore(headers, key, 0, {key, value})
      end)

    Conn.resp(%{conn | resp_headers: headers}, status, body)
  end

  defp put_expires_header(conn, expires) do
    Conn.put_resp_header(conn, "expires", __imf_fixdate__(expires))
  end

  @doc false
  def __imf_fixdate__(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %X GMT")
  end

  defp ensure_is_halted!(conn, error, mod, fun, args) do
    case apply(mod, fun, [conn, error | args]) do
      %Conn{halted: true} = conn ->
        conn

      other ->
        raise ArgumentError, "option :with MUST return a halted conn, got: #{inspect(other)}"
    end
  end
end
