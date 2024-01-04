defmodule IdempotencyPlug.RequestTrackerTest do
  use ExUnit.Case

  alias IdempotencyPlug.RequestTracker

  setup context do
    opts = Keyword.merge([name: __MODULE__], context[:options] || [])
    pid = start_supervised!({RequestTracker, opts})

    {:ok, pid: pid}
  end

  test "with no cached response", %{pid: pid} do
    expires_after = DateTime.add(DateTime.utc_now(), 24, :hour)

    assert {:init, key, expires} = RequestTracker.track(pid, "no-cache", "fingerprint")
    assert DateTime.compare(expires, expires_after) != :lt

    assert {:ok, expires} = RequestTracker.put_response(pid, key, "OK")
    assert DateTime.compare(expires, expires_after) != :lt
  end

  test "with concurrent requests", %{pid: pid} do
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

    assert {:mismatch, {:fingerprint, "fingerprint"}, ^expires} =
             RequestTracker.track(pid, "cached-fingerprint", "other-fingerprint")
  end

  test "with cached response", %{pid: pid} do
    {:init, key, _expires} = RequestTracker.track(pid, "cached-response", "fingerprint")
    {:ok, expires} = RequestTracker.put_response(pid, key, "OK")

    assert {:cache, {:ok, "OK"}, ^expires} =
             RequestTracker.track(pid, "cached-response", "fingerprint")
  end

  @tag capture_log: true
  test "with halted process", %{pid: pid} do
    Process.flag(:trap_exit, true)

    task =
      Task.async(fn ->
        {:init, _id, _expires} = RequestTracker.track(pid, "halted-request", "fingerprint")
        raise "oops"
      end)

    {{%RuntimeError{message: "oops"}, _}, _} = catch_exit(Task.await(task))

    assert {:cache, {:halted, {%RuntimeError{message: "oops"}, _}}, _expires} =
             RequestTracker.track(pid, "halted-request", "fingerprint")
  end

  test "when no tracked request", %{pid: pid} do
    assert {:error, "key no-request not found in store"} =
             RequestTracker.put_response(pid, "no-request", "OK")
  end

  @tag options: [prune: 5, cache_ttl: 10]
  test "prunes", %{pid: pid} do
    {:init, _id, _expires} = RequestTracker.track(pid, "prune", "fingerprint")

    assert {:processing, _node_caller, _expires} =
             RequestTracker.track(pid, "prune", "fingerprint")

    :timer.sleep(20)
    assert {:init, _id, _expires} = RequestTracker.track(pid, "prune", "fingerprint")
  end
end
