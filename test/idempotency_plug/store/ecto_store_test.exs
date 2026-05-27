defmodule IdempotencyPlug.EctoStoreTest do
  use ExUnit.Case

  import IdempotencyPlug, only: [sha256_hash: 2]
  import ExUnit.CaptureIO

  alias IdempotencyPlug.EctoStore

  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :idempotency_plug,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule UnmigratedTestRepo do
    use Ecto.Repo,
      otp_app: :idempotency_plug,
      adapter: Ecto.Adapters.Postgres
  end

  setup_all :setup_ecto_repo
  setup :setup_ecto_sandbox

  @options [repo: TestRepo]
  @request_id sha256_hash(:idempotency_key, {"key", ["/"]})
  @other_request_id sha256_hash(:idempotency_key, {"other-key", ["/"]})
  @data {:ok, %{resp_body: "OK", resp_headers: [], status: 200}}
  @updated_data {:halted, :terminated}
  @fingerprint sha256_hash(:request_payload, %{"a" => 1})

  describe "setup/1" do
    test "when `:repo` option is missing" do
      assert EctoStore.setup([]) ==
               {:error, ":repo must be specified in options for IdempotencyPlug.EctoStore"}
    end

    test "when not migrated" do
      Application.put_env(
        :idempotency_plug,
        UnmigratedTestRepo,
        postgres_repo_options("idempotency_plug_unmigrated_test")
      )

      UnmigratedTestRepo.__adapter__().storage_down(UnmigratedTestRepo.config())
      :ok = UnmigratedTestRepo.__adapter__().storage_up(UnmigratedTestRepo.config())

      start_supervised!(UnmigratedTestRepo)

      on_exit(fn ->
        UnmigratedTestRepo.__adapter__().storage_down(UnmigratedTestRepo.config())
      end)

      assert EctoStore.setup(repo: UnmigratedTestRepo) ==
               {:error,
                "The table idempotency_plug_requests is not accessible. Did you generate the Ecto migration with `mix idempotency_plug.ecto.gen.migration`?"}
    end

    test "when migrated" do
      assert EctoStore.setup(@options) == :ok
    end
  end

  test "inserts, looks up, and updates" do
    :ok = EctoStore.setup(@options)

    assert EctoStore.lookup(@request_id, @options) == :not_found

    expires_at = DateTime.utc_now()
    assert EctoStore.insert(@request_id, @data, @fingerprint, expires_at, @options) == :ok

    assert {:error, _changeset} =
             EctoStore.insert(@request_id, @data, @fingerprint, expires_at, @options)

    assert EctoStore.lookup(@request_id, @options) == {@data, @fingerprint, expires_at}

    updated_expires_at = DateTime.utc_now()

    assert EctoStore.update(@other_request_id, @updated_data, updated_expires_at, @options) ==
             {:error, "key #{@other_request_id} not found in store"}

    assert EctoStore.update(@request_id, @updated_data, updated_expires_at, @options) == :ok

    assert EctoStore.lookup(@request_id, @options) ==
             {@updated_data, @fingerprint, updated_expires_at}
  end

  test "prevents decoding of unsafe data" do
    :ok = EctoStore.setup(@options)

    unsafe_data = <<131, 119, 8, "tjenixen">>

    assert EctoStore.insert(@request_id, @data, @fingerprint, DateTime.utc_now(), @options) == :ok

    TestRepo.query!("UPDATE idempotency_plug_requests SET data = $1 WHERE id = $2", [
      unsafe_data,
      @request_id
    ])

    assert_raise ArgumentError, ~r/invalid or unsafe external representation of a term/, fn ->
      EctoStore.lookup(@request_id, @options)
    end
  end

  test "prunes" do
    :ok = EctoStore.setup(@options)

    expired = DateTime.add(DateTime.utc_now(), -1, :second)
    not_expired = DateTime.add(DateTime.utc_now(), 1, :second)

    assert EctoStore.insert(@request_id, @data, @fingerprint, expired, @options) == :ok
    assert EctoStore.insert(@other_request_id, @data, @fingerprint, not_expired, @options) == :ok

    assert EctoStore.prune(@options) == :ok

    assert EctoStore.lookup(@request_id, @options) == :not_found
    refute EctoStore.lookup(@other_request_id, @options) == :not_found
  end

  @tmp_path "tmp/#{inspect(__MODULE__)}"

  defp setup_ecto_repo(_) do
    File.rm_rf!(@tmp_path)
    File.mkdir_p!(@tmp_path)
    File.cd!(@tmp_path)

    Application.put_env(
      :idempotency_plug,
      TestRepo,
      postgres_repo_options("idempotency_plug_test")
    )

    capture_io(fn ->
      Mix.Task.run("idempotency_plug.ecto.gen.migration", ["-r", inspect(TestRepo)])
    end)

    TestRepo.__adapter__().storage_down(TestRepo.config())
    :ok = TestRepo.__adapter__().storage_up(TestRepo.config())

    start_supervised!(TestRepo)

    migrations_path = Path.join("priv", "repo")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(
        TestRepo,
        &Ecto.Migrator.run(&1, migrations_path, :up, all: true, log: false)
      )

    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

    :ok
  end

  defp postgres_repo_options(database) do
    base_url = System.get_env("POSTGRES_BASE_URL")

    [
      database: database,
      pool: Ecto.Adapters.SQL.Sandbox,
      priv: "priv/repo",
      log: false,
      url: base_url && "#{base_url}/#{database}"
    ]
  end

  defp setup_ecto_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    :ok
  end
end
