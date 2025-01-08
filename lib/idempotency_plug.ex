defmodule IdempotencyPlug do
  defmodule NoHeadersError do
    @moduledoc """
    There's no Idempotency-Key request headers.
    """

    defexception message:
                   "No idempotency key found. You need to set the `Idempotency-Key` header for all POST requests: 'Idempotency-Key: KEY'",
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

  @moduledoc """
  Plug that handles `Idempotency-Key` HTTP headers.

  A single `Idempotency-Key` HTTP header is required for POST and PATCH requests.

  Handling of requests is based on
  https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/

  ### Idempotency Key

  The value of the `Idempotency-Key` HTTP header is combined with a URI to
  produce a unique sha256 hash for the request. This will be used to store the
  response for first-time requests. The key is used to fetch this response in
  all subsequent requests.

  A sha256 hash of the request payload is generated and used to ensure the key
  is not reused with a different request payload.

  ### Error handling

  By default, errors are raised and handled by the `Plug.Exception` protocol:

    - Concurrent requests raises `IdempotencyPlug.ConcurrentRequestError`
      which sets `409 Conflict` HTTP status code.
    - Mismatch of request payload fingerprint will raise
      `IdempotencyPlug.RequestPayloadFingerprintMismatchError` which sets
      `422 Unprocessable Entity` HTTP status code.
    - If the first-time request was unexpectedly terminated a
      `IdempotencyPlug.HaltedResponseError` which sets a `500 Internal Server`
      error is raised.

  Setting `:with` option with an MFA will catch and pass the error to the MFA.

  ### Cached responses

  Cached responses returns an `Expires` header in the response. See
  `IdempotencyPlug.RequestTracker` for more on expiration.

  ## Options

    * `:tracker` - must be a name or PID for the
      `IdempotencyPlug.RequestTracker` GenServer, required.

    * `:idempotency_key` - should be a MFA callback to process idempotency key.
      Defaults to `{#{__MODULE__}, :idempotency_key}`.

    * `:request_payload` - should be a MFA to parse request payload. Defaults
      to `{#{__MODULE__}, :request_payload}`.

    * `:hash` - should be a MFA to hash an Erlang term. Defaults to
      `{#{__MODULE__}, :sha256_hash}`.

    * `:with` - should be one of `:exception` or MFA. Defaults to `:exception`.
      - `:exception` - raises an error.
      - `{mod, fun, args}` - calls the MFA to process the conn with error, the
        connection MUST be halted.

  ## Telemetry events

  The following events are emitted by the Plug:

    * `[:idempotency_plug, :track, :start]` - dispatched before request tracking
      * Measurement: `%{system_time: System.system_time}`
      * Metadata: `%{telemetry_span_context: term(), conn: Plug.Conn.t, tracker: module, idempotency_key: binary}`
      tracker: tracker,
      idempotency_key: key

    * `[:idempotency_plug, :track, :exception]` - dispatched after exceptions on tracking a request
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{telemetry_span_context: term(), conn: Plug.Conn.t, tracker: module, idempotency_key: binary, kind: :throw | :error | :exit, reason: term(), stacktrace: list()}`

    * `[:idempotency_plug, :track, :stop]` - dispatched after successfully tracking a request
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{telemetry_span_context: term(), conn: Plug.Conn.t, tracker: module, idempotency_key: binary}`

  ## Examples

      plug IdempotencyPlug,
        tracker: IdempotencyPlug.RequestTracker,
        idempotency_key: {__MODULE__, :scope_idempotency_key},
        request_payload: {__MODULE__, :limit_request_payload},
        hash: {__MODULE__, :sha512_hash},
        with: {__MODULE__, :handle_error}

      def scope_idempotency_key(conn, key) do
        {conn.assigns.user.id, key}
      end

      def limit_request_payload(conn) do
        Map.drop(conn.params, ["value"])
      end

      def sha512_hash(_key, value) do
        :sha512
        |> :crypto.hash(:erlang.term_to_binary(value))
        |> Base.encode16()
        |> String.downcase()
      end

      def handle_error(conn, error) do
        conn
        |> put_status(error.plug_status)
        |> json(%{message: error.message})
        |> halt()
      end
  """
  @behaviour Plug

  alias Plug.Conn

  alias IdempotencyPlug.RequestTracker

  @doc false
  @impl true
  def init(opts) do
    case Keyword.get(opts, :tracker) do
      pid when is_pid(pid) ->
        :ok

      atom when is_atom(atom) and not is_nil(atom) ->
        :ok

      other ->
        raise ArgumentError,
              "option :tracker must be one of PID or Atom, got: #{inspect(other)}"
    end

    opts
  end

  @doc false
  @impl true
  def call(%{method: method} = conn, opts) when method in ~w(POST PATCH) do
    case Conn.get_req_header(conn, "idempotency-key") do
      [key] -> handle_idempotent_request(conn, key, opts)
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
      case Keyword.get(opts, :with, :exception) do
        :exception ->
          reraise error, __STACKTRACE__

        {mod, fun} ->
          ensure_is_halted!(conn, error, mod, fun)

        {mod, fun, args} ->
          ensure_is_halted!(conn, error, mod, fun, args)

        other ->
          # credo:disable-for-next-line Credo.Check.Warning.RaiseInsideRescue
          raise ArgumentError,
                "option :with should be one of :exception or MFA, got: #{inspect(other)}"
      end
  end

  def call(conn, _opts), do: conn

  defp handle_idempotent_request(conn, key, opts) do
    tracker = Keyword.fetch!(opts, :tracker)

    idempotency_key_hash = hash_idempotency_key(conn, key, opts)
    request_payload_hash = hash_request_payload(conn, opts)

    metadata = %{
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
            |> put_expires_header(expires)
            |> set_resp(response)
            |> Conn.halt()

          {conn, %{metadata | conn: conn}}

        {:init, idempotency_key, _expires} ->
          conn = update_response_before_send(conn, idempotency_key, opts)

          {conn, %{metadata | conn: conn}}

        {:error, error} ->
          raise "failed to track request, got: #{error}"
      end
    end)
  end

  @doc """
  Returns the key as-is.
  """
  def idempotency_key(_conn, key), do: key

  defp hash_idempotency_key(conn, key, opts) do
    key = {key, conn.path_info}

    processed_key =
      case Keyword.get(opts, :idempotency_key, {__MODULE__, :idempotency_key}) do
        {mod, fun} ->
          apply(mod, fun, [conn, key])

        {mod, fun, args} ->
          apply(mod, fun, [conn, key | args])

        other ->
          raise ArgumentError, "option :idempotency_key must be a MFA, got: #{inspect(other)}"
      end

    hash(:idempotency_key, processed_key, opts)
  end

  @doc """
  Sorts the request params in a deterministic order.
  """
  def request_payload(conn) do
    # Maps are not guaranteed to be ordered so we'll sort it here
    conn.params
    |> Map.to_list()
    |> Enum.sort()
  end

  defp hash_request_payload(conn, opts) do
    payload =
      case Keyword.get(opts, :request_payload, {__MODULE__, :request_payload}) do
        {mod, fun} ->
          apply(mod, fun, [conn])

        {mod, fun, args} ->
          apply(mod, fun, [conn | args])

        other ->
          raise ArgumentError,
                "option :request_payload must be a MFA tuple, got: #{inspect(other)}"
      end

    hash(:request_payload, payload, opts)
  end

  defp hash(key, value, opts) do
    case Keyword.get(opts, :hash, {__MODULE__, :sha256_hash}) do
      {mod, fun} -> apply(mod, fun, [key, value])
      {mod, fun, args} -> apply(mod, fun, [key, value | args])
      other -> raise ArgumentError, "option :hash must be a MFA tuple, got: #{inspect(other)}"
    end
  end

  @doc """
  Encodes the value from an Erlang term to a binary and generates a sha256 hash
  from it.
  """
  def sha256_hash(_key, value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16()
    |> String.downcase()
  end

  defp update_response_before_send(conn, key, opts) do
    tracker = Keyword.fetch!(opts, :tracker)

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

  defp set_resp(conn, %{resp_body: body, resp_headers: headers, status: status}) do
    headers
    |> Enum.reduce(conn, fn {key, value}, conn ->
      Conn.put_resp_header(conn, key, value)
    end)
    |> Conn.resp(status, body)
  end

  defp put_expires_header(conn, expires) do
    expires =
      expires
      |> DateTime.shift_zone!("Etc/UTC")
      |> Calendar.strftime("%a, %-d %b %Y %X GMT")

    Conn.put_resp_header(conn, "expires", expires)
  end

  defp ensure_is_halted!(conn, error, mod, fun, args \\ []) do
    mod
    |> apply(fun, [conn, error | args])
    |> case do
      %Conn{halted: true} = conn ->
        conn

      other ->
        raise ArgumentError, "option :with MUST return a halted conn, got: #{inspect(other)}"
    end
  end
end
