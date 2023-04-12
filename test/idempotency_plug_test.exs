defmodule IdempotencyPlugTest do
  use ExUnit.Case

  import Plug.Conn

  alias IdempotencyPlug.RequestTracker

  setup [:setup_tracker, :setup_request]

  test "with no tracker" do
    assert_raise ArgumentError, "option :tracker must be one of PID or Atom, got: nil", fn ->
      IdempotencyPlug.init([])
    end
  end

  test "with invalid tracker" do
    assert_raise ArgumentError, "option :tracker must be one of PID or Atom, got: \"invalid\"", fn ->
      IdempotencyPlug.init(tracker: "invalid")
    end
  end

  test "with no idempotency header set", %{conn: conn, tracker: tracker} do
    error =
      assert_raise IdempotencyPlug.NoHeadersError, fn ->
        conn
        |> delete_req_header("idempotency-key")
        |> run_plug(tracker)
      end

    assert Plug.Exception.status(error) == 400
    assert error.message =~ "No idempotency key found"
  end

  test "with too many idempotency headers set", %{conn: conn, tracker: tracker} do
    error =
      assert_raise IdempotencyPlug.MultipleHeadersError, fn ->
        conn
        |> Map.put(:req_headers, conn.req_headers ++ [{"idempotency-key", "other-key"}])
        |> run_plug(tracker)
      end

    assert Plug.Exception.status(error) == 400
    assert error.message =~ "Only one `Idempotency-Key` header can be sent"
  end

  test "with no idempotency header set and GET header", %{conn: conn, tracker: tracker} do
    conn =
      conn
      |> delete_req_header("idempotency-key")
      |> Map.put(:method, "GET")
      |> run_plug(tracker)

    refute conn.halted
    assert conn.resp_body == "OK"
    refute expires(conn)
  end

  test "with no cached response", %{conn: conn, tracker: tracker} do
    conn = run_plug(conn, tracker)

    refute conn.halted
    assert conn.status == 200
    assert conn.resp_body == "OK"
    assert expires(conn)
  end

  test "with concurrent request", %{conn: conn, tracker: tracker} do
    pid = self()

    task =
      Task.async(fn ->
        run_plug(conn, tracker, callback: fn conn ->
          send(pid, :continue)
          receive do
            :continue -> :ok
          end
          conn
        end)
      end)

    receive do
      :continue -> :ok
    end

    error =
      assert_raise IdempotencyPlug.ConcurrentRequestError, fn ->
        run_plug(conn, tracker)
      end

    assert Plug.Exception.status(error) == 409
    assert error.message =~ "A request with the same `Idempotency-Key` is currently being processed"

    send(task.pid, :continue)
    Task.await(task)
  end

  @tag capture_log: true
  test "with halted response", %{conn: conn, tracker: tracker} do
    Process.flag(:trap_exit, true)
    task = Task.async(fn -> run_plug(conn, tracker, callback: fn _conn -> raise "failed" end) end)
    {{%RuntimeError{}, _}, _} = catch_exit(Task.await(task))

    error =
      assert_raise IdempotencyPlug.HaltedResponseError, fn ->
        run_plug(conn, tracker)
      end

    assert Plug.Exception.status(error) == 500
    assert error.message =~ "The original request was interrupted and can't be recovered as it's in an unknown state"
  end

  test "with cached response", %{conn: conn, tracker: tracker} do
    other_conn =
      run_plug(conn, tracker, callback: fn conn ->
        conn
        |> put_resp_header("x-header-key", "header-value")
        |> send_resp(201, "OTHER")
      end)

    conn = run_plug(conn, tracker)

    assert conn.halted
    assert conn.status == 201
    assert conn.resp_body == "OTHER"
    assert expires(conn) == expires(other_conn)
    assert get_resp_header(conn, "x-header-key") == ["header-value"]
  end

  test "with cached response with different request payload", %{conn: conn, tracker: tracker} do
    _other_conn =
      conn
      |> other_request_payload()
      |> run_plug(tracker, callback: &send_resp(&1, 201, "OTHER"))

    error =
      assert_raise IdempotencyPlug.RequestPayloadFingerprintMismatchError, fn ->
        run_plug(conn, tracker)
      end

    assert Plug.Exception.status(error) == 422
    assert error.message =~ "This `Idempotency-Key` can't be reused with a different payload or URI"
  end

  test "with cached response with different request URI", %{conn: conn, tracker: tracker} do
    _other_conn =
      conn
      |> other_request_path()
      |> run_plug(tracker, callback: &send_resp(&1, 201, "OTHER"))

    conn = run_plug(conn, tracker)

    refute conn.halted
    assert conn.status == 200
    assert conn.resp_body == "OK"
  end

  test "with invalid `:idempotency_key`", %{conn: conn, tracker: tracker} do
    assert_raise ArgumentError, "option :idempotency_key must be a MFA, got: :invalid", fn ->
      run_plug(conn, tracker, idempotency_key: :invalid)
    end
  end

  def scope_idempotency_key(conn, key, :arg1), do: {conn.assigns.custom, key}

  test "with `:idempotency_key`", %{conn: conn, tracker: tracker} do
    opts = [idempotency_key: {__MODULE__, :scope_idempotency_key, [:arg1]}]

    resp_conn =
      conn
      |> assign(:custom, "a")
      |> run_plug(tracker, opts ++ [callback: &send_resp(&1, 201, "OTHER")])

    refute resp_conn.halted
    assert resp_conn.status == 201
    assert resp_conn.resp_body == "OTHER"

    resp_conn =
      conn
      |> assign(:custom, "b")
      |> run_plug(tracker, opts)

    refute resp_conn.halted
    assert resp_conn.status == 200
    assert resp_conn.resp_body == "OK"

    resp_conn =
      conn
      |> assign(:custom, "a")
      |> run_plug(tracker, opts)

    assert resp_conn.halted
    assert resp_conn.status == 201
    assert resp_conn.resp_body == "OTHER"

    assert_raise IdempotencyPlug.RequestPayloadFingerprintMismatchError, fn ->
      conn
      |> assign(:custom, "a")
      |> other_request_payload()
      |> run_plug(tracker, opts)
    end
  end

  test "with invalid `:hash`", %{conn: conn, tracker: tracker} do
    assert_raise ArgumentError, "option :hash must be a MFA tuple, got: :invalid", fn ->
      run_plug(conn, tracker, hash: :invalid)
    end
  end

  def static_hash(_key, _value, :arg1), do: "hash"

  test "with `:hash`", %{conn: conn, tracker: tracker} do
    opts = [hash: {__MODULE__, :static_hash, [:arg1]}]

    other_conn = run_plug(conn, tracker, opts ++ [callback: &send_resp(&1, 201, "OTHER")])

    refute other_conn.halted
    assert other_conn.status == 201
    assert other_conn.resp_body == "OTHER"

    conn =
      conn
      |> other_request_payload()
      |> other_request_path()
      |> run_plug(tracker, opts)

    assert conn.halted
    assert conn.status == 201
    assert conn.resp_body == "OTHER"
  end

  test "with invalid `:request_payload`", %{conn: conn, tracker: tracker} do
    assert_raise ArgumentError, "option :request_payload must be a MFA tuple, got: :invalid", fn ->
      run_plug(conn, tracker, request_payload: :invalid)
    end
  end

  def scope_request_payload(conn, :arg1), do: Map.take(conn.params, ["a"])

  test "with `:request_payload`", %{conn: conn, tracker: tracker} do
    opts = [request_payload: {__MODULE__, :scope_request_payload, [:arg1]}]

    _resp_conn =
      conn
      |> Map.put(:params, %{"a" => 1, "b" => 2})
      |> run_plug(tracker, opts ++ [callback: &send_resp(&1, 201, "OTHER")])

    resp_conn =
      conn
      |> Map.put(:params, %{"a" => 1, "b" => 1})
      |> run_plug(tracker, opts)

    assert resp_conn.halted
    assert resp_conn.status == 201
    assert resp_conn.resp_body == "OTHER"

    error =
      assert_raise IdempotencyPlug.RequestPayloadFingerprintMismatchError, fn ->
        conn
        |> Map.put(:params,  %{"a" => 2})
        |> run_plug(tracker, opts)
      end

    assert Plug.Exception.status(error) == 422
    assert error.message =~ "This `Idempotency-Key` can't be reused with a different payload or URI"
  end

  test "with invalid `:with`", %{conn: conn, tracker: tracker} do
    assert_raise ArgumentError, "option :with should be one of :exception or MFA, got: :invalid", fn ->
      conn
      |> other_request_payload()
      |> run_plug(tracker, with: :invalid)

      run_plug(conn, tracker, with: :invalid)
    end
  end

  def handle_error(conn, error, :arg1) do
    conn
    |> resp(error.plug_status, error.message)
    |> halt()
  end

  def handle_error_unhalted(conn, _error), do: conn

  test "with `:with`", %{conn: conn, tracker: tracker} do
    opts = [with: {__MODULE__, :handle_error, [:arg1]}]

    _other_conn =
      conn
      |> other_request_payload()
      |> run_plug(tracker, opts)

    resp_conn = run_plug(conn, tracker, opts)

    assert resp_conn.halted
    assert resp_conn.status == 422
    assert resp_conn.resp_body == "This `Idempotency-Key` can't be reused with a different payload or URI"

    assert_raise ArgumentError, ~r/option :with MUST return a halted conn, got: %Plug.Conn{/, fn ->
     run_plug(conn, tracker, with: {__MODULE__, :handle_error_unhalted})
    end
  end

  defp setup_tracker(_) do
    tracker = start_supervised!({RequestTracker, [name: __MODULE__]})

    %{tracker: tracker}
  end

  defp setup_request(_) do
    conn =
      %Plug.Conn{}
      |> Plug.Adapters.Test.Conn.conn("POST", "/my/path", nil)
      |> put_req_header("idempotency-key", "key")
      |> Map.put(:params, %{"a" => 1, "b" => 2})

    %{conn: conn}
  end

  defp run_plug(conn, tracker, opts \\ []) do
    {callback, opts} = Keyword.pop(opts, :callback)
    callback = callback || &send_resp(&1, 200, "OK")

    conn
    |> IdempotencyPlug.call(IdempotencyPlug.init([tracker: tracker] ++ opts))
    |> case do
      %{halted: true} = conn -> send_resp(conn)
      conn -> callback.(conn)
    end
  end

  defp expires(conn) do
    case get_resp_header(conn, "expires") do
      [expires] -> expires
      [] -> nil
    end
  end

  defp other_request_payload(conn), do: %{conn | params: %{"other_key" => "1"}}

  defp other_request_path(conn), do: %{conn | path_info: ["other", "path"]}
end
