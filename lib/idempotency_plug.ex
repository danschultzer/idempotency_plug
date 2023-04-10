defmodule IdempotencyPlug do
  @moduledoc """
  Plug that handles `Idempotency-Key` HTTP headers.

  A single `Idempotency-Key` HTTP header is required for POST and PATCH requests.

  Handling of requests is based on
  https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/

  ### Request ID

  The value of the `Idempotency-Key` HTTP header is combined with a URI to
  produce a unique sha256 hash for the request. This will be used to store the
  response for first-time requests. The ID is used to fetch this response in
  all subsequent requests.

  A sha256 checksum of the request payload is generated and used to ensure the
  ID is not reused with a different request payload.

  ### Error handling

    - Concurrent requests will return a `409 Conflict` response.
    - Mismatch of request payload fingerprint will return
      `422 Unprocessable Entity` response.
    - If the first-time request was unexpectedly terminated a
      `500 Internal Server` is returned.

  Cached responses and halted first-time requests, returning an `Expires`
  header in the response.

  See `IdempotencyPlug.RequestTracker` for more on expiration.

  ## Options

    * `:handler` - the handler module to use for building the idempotent id and
      error response. Defaults to `IdempotencyPlug.Handler`.
      See `IdempotencyPlug.Handler` for more.

    * `:tracker` - the name or pid for the `IdempotencyPlug.RequestTracker`
      GenServer. Defaults to `IdempotencyPlug.RequestTracker`.

  ## Examples

      plug IdempotencyPlug,
        tracker: IdempotencyPlug.RequestTracker,
        handler: IdempotencyPlug.Handler
  """
  @behaviour Plug

  alias Plug.Conn

  alias IdempotencyPlug.{Handler, RequestTracker}

  @doc false
  @impl true
  def init(opts) do
    Keyword.merge([tracker: RequestTracker, handler: Handler], opts)
  end

  @doc false
  @impl true
  def call(%{method: method} = conn, opts) when method in ~w(POST PATCH) do
    case Conn.get_req_header(conn, "idempotency-key") do
      [id] -> handle_idempotent_request(conn, id, opts)
      [_ | _] -> halt_error(conn, :multiple_headers, opts)
      [] -> halt_error(conn, :no_headers, opts)
    end
  end

  def call(conn, _opts), do: conn

  defp handle_idempotent_request(conn, id, opts) do
    tracker = Keyword.fetch!(opts, :tracker)
    idempotent_id = gen_idempotent_id(conn, id, opts)
    fingerprint = gen_request_payload_fingerprint(conn)

    case RequestTracker.track(tracker, idempotent_id, fingerprint) do
      {:processing, _node_caller, _expires} ->
        halt_error(conn, :concurrent_request, opts)

      {:mismatch, {:fingerprint, _fingerprint}, _expires} ->
        halt_error(conn, :fingerprint_mismatch, opts)

      {:cache, {:halted, _reason}, expires} ->
        conn
        |> put_expires_header(expires)
        |> halt_error(:halted, opts)

      {:cache, {:ok, response}, expires} ->
        conn
        |> put_expires_header(expires)
        |> set_resp(response)
        |> Conn.halt()

      {:init, id, _expires} ->
        update_response_before_send(conn, id, opts)

      {:error, error} ->
        raise "Couldn't track request, got: #{error}"
    end
  end

  defp gen_idempotent_id(conn, id, opts) do
    handler = Keyword.fetch!(opts, :handler)
    id = handler.idempotent_id(conn, id)

    sha256_checksum({id, conn.path_info})
  end

  defp sha256_checksum(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term))
    |> Base.encode16()
    |> String.downcase()
  end

  defp gen_request_payload_fingerprint(conn) do
    # Maps are not guaranteed to be ordered so we'll sort it here
    sha256_checksum(conn.params |> Map.to_list() |> Enum.sort())
  end

  defp update_response_before_send(conn, id, opts) do
    tracker = Keyword.fetch!(opts, :tracker)

    Conn.register_before_send(conn, fn conn ->
      case RequestTracker.put_response(tracker, id, conn_to_response(conn)) do
        {:ok, expires} -> put_expires_header(conn, expires)
        {:error, error} -> raise "Couldn't store response, got: #{inspect error}"
      end
    end)
  end

  defp halt_error(conn, error, opts) do
    handler = Keyword.fetch!(opts, :handler)

    conn
    |> handler.resp_error(error)
    |> Conn.halt()
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

  if Mix.env == :test do
    # This is only included in tests
    def __sha256_checksum__(term), do: sha256_checksum(term)
  end
end
