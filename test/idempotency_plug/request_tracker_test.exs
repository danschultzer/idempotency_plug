defmodule IdempotencyPlug.RequestTrackerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias __MODULE__.FakeStore
  alias IdempotencyPlug.RequestTracker

  setup context do
    opts = Keyword.merge([name: __MODULE__], context[:options] || [])
    pid = start_supervised!({RequestTracker, opts})

    {:ok, pid: pid}
  end

  describe "track/3" do
    test "with uncached request", %{pid: pid} do
      expires_after = DateTime.add(DateTime.utc_now(), 24, :hour)
      ref = attach_request_tracker_telemetry_events([:cache_miss])

      assert {:init, key, expires} = RequestTracker.track(pid, "no-cache", "fingerprint")
      assert DateTime.compare(expires, expires_after) != :lt

      {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, :cache_miss)
      assert metadata.request_id == key
      assert metadata.fingerprint == "fingerprint"
      assert metadata.store == IdempotencyPlug.ETSStore
      assert metadata.expires_at == expires
      assert metadata.result == :ok
      assert is_nil(metadata.reason)

      assert {:ok, expires} = RequestTracker.put_response(pid, key, "OK")
      assert DateTime.compare(expires, expires_after) != :lt
    end

    @tag options: [store: {FakeStore, [insert: {:error, %RuntimeError{message: "boom"}}]}]
    test "with uncache response when store insert fails", %{pid: pid} do
      ref = attach_request_tracker_telemetry_events([:cache_miss])

      assert {:error, %RuntimeError{}} = RequestTracker.track(pid, "no-cache", "fingerprint")

      {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, :cache_miss)
      assert is_nil(metadata.expires_at)
      assert metadata.result == :error
      assert metadata.reason == %RuntimeError{message: "boom"}
    end

    test "with a concurrent request", %{pid: pid} do
      ref = attach_request_tracker_telemetry_events([:cache_hit])
      test_pid = self()

      task =
        Task.async(fn ->
          {:init, key, expires} = RequestTracker.track(pid, "concurrent-request", "fingerprint")

          send(test_pid, {:expires, expires})

          receive do
            :continue -> :ok
          end

          {:ok, expires} = RequestTracker.put_response(pid, key, "OK")

          send(test_pid, {:expires, expires})
        end)

      receive do
        {:expires, expires} ->
          assert {:processing, _node_caller, ^expires} =
                   RequestTracker.track(pid, "concurrent-request", "fingerprint")

          {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, :cache_hit)
          assert metadata.expires_at == expires
          assert metadata.result == :processing
          assert is_nil(metadata.reason)
      end

      send(task.pid, :continue)

      receive do
        {:expires, expires} ->
          assert {:cache, {:ok, "OK"}, ^expires} =
                   RequestTracker.track(pid, "concurrent-request", "fingerprint")
      end
    end

    test "with fingerprint mismatch", %{pid: pid} do
      {:init, key, _expires} = RequestTracker.track(pid, "cached-fingerprint", "fingerprint")
      {:ok, expires} = RequestTracker.put_response(pid, key, "OK")
      ref = attach_request_tracker_telemetry_events([:cache_hit])

      assert {:mismatch, {:fingerprint, "fingerprint"}, ^expires} =
               RequestTracker.track(pid, "cached-fingerprint", "other-fingerprint")

      {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, :cache_hit)
      assert metadata.expires_at == expires
      assert metadata.result == :mismatch
      assert is_nil(metadata.reason)
    end

    test "with cached response", %{pid: pid} do
      {:init, key, _expires} = RequestTracker.track(pid, "cached-response", "fingerprint")
      {:ok, expires} = RequestTracker.put_response(pid, key, "OK")
      ref = attach_request_tracker_telemetry_events([:cache_hit])

      assert {:cache, {:ok, "OK"}, ^expires} =
               RequestTracker.track(pid, "cached-response", "fingerprint")

      {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, :cache_hit)
      assert metadata.expires_at == expires
      assert metadata.result == :ok
      assert is_nil(metadata.reason)
    end

    @tag capture_log: true
    test "with crashed process", %{pid: pid} do
      Process.flag(:trap_exit, true)

      task =
        Task.async(fn ->
          {:init, _id, _expires} = RequestTracker.track(pid, "halted-request", "fingerprint")
          raise "boom"
        end)

      {{%RuntimeError{message: "boom"}, _}, _} = catch_exit(Task.await(task))

      ref = attach_request_tracker_telemetry_events([:cache_hit])

      assert {:cache, {:halted, {%RuntimeError{message: "boom"}, _}}, expires} =
               RequestTracker.track(pid, "halted-request", "fingerprint")

      {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, :cache_hit)
      assert metadata.expires_at == expires
      assert metadata.result == :halted
      assert {%RuntimeError{message: "boom"}, _} = metadata.reason
    end

    @tag options: [prune: 5, cache_ttl: 10]
    test "with expired cache", %{pid: pid} do
      {:init, _id, _expires} = RequestTracker.track(pid, "prune", "fingerprint")

      assert {:processing, _node_caller, _expires} =
               RequestTracker.track(pid, "prune", "fingerprint")

      ref = attach_request_tracker_telemetry_events([[:prune, :start], [:prune, :stop]])

      :timer.sleep(20)
      assert {:init, _id, _expires} = RequestTracker.track(pid, "prune", "fingerprint")

      {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, [:prune, :start])
      assert metadata.store == IdempotencyPlug.ETSStore
      {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, [:prune, :stop])
      assert metadata.store == IdempotencyPlug.ETSStore
    end
  end

  describe "put_response/3" do
    test "with no tracked request", %{pid: pid} do
      assert RequestTracker.put_response(pid, "no-request", "OK") ==
               {:error, "key no-request not found in store"}
    end
  end

  @tag options: [store: {FakeStore, []}, prune: 5]
  test "with pruning when store delete raises", %{pid: pid} do
    monitor_ref = Process.monitor(pid)
    ref = attach_request_tracker_telemetry_events([[:prune, :start], [:prune, :exception]])

    log =
      capture_log(fn ->
        :timer.sleep(20)

        assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}
      end)

    assert log =~ "(RuntimeError) boom"

    {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, [:prune, :start])
    assert metadata.store == FakeStore
    {_measurements, metadata} = assert_request_tracker_telemetry_event(ref, [:prune, :exception])
    assert metadata.store == FakeStore
  end

  defp attach_request_tracker_telemetry_events(events) do
    :telemetry_test.attach_event_handlers(
      self(),
      Enum.map(events, fn event ->
        List.flatten([:idempotency_plug, :request_tracker, event])
      end)
    )
  end

  defp assert_request_tracker_telemetry_event(ref, event) do
    event_name = List.flatten([:idempotency_plug, :request_tracker, event])

    assert_receive {^event_name, ^ref, measurements, metadata}

    {measurements, metadata}
  end

  defmodule FakeStore do
    @moduledoc false
    @behaviour IdempotencyPlug.Store

    @impl true
    def setup(_opts), do: :ok

    @impl true
    def lookup(_id, _opts), do: :not_found

    @impl true
    def insert(_id, _data, _fp, _expires, opts), do: Keyword.get(opts, :insert, :ok)

    @impl true
    def update(_id, _data, _expires, _opts), do: :ok

    @impl true
    def prune(_opts), do: raise("boom")
  end
end
