defmodule IdempotencyPlug.ETSStore do
  @moduledoc """
  Module that defines an ETS store.

  The ETS table data is not persisted and will be flushed on application
  restart. You should use the `IdempotencyPlug.EctoStore` or a custom
  `IdempotencyPlug.Store` type module for production.

  ## Examples

      defmodule MyApp.Application do
        # ..

        def start(_type, _args) do
          children = [
            {IdempotencyPlug.RequestTracker, [
              store: {IdempotencyPlug.EctoStore, [table: MyAppWeb.RequestTrackerStore]}]}
            # ...
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end
  """
  @behaviour IdempotencyPlug.Store

  @impl true
  def setup(opts) do
    case table(opts) do
      {:ok, table} ->
        :ets.new(table, [:named_table, :ordered_set, :private])

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def lookup(request_id, opts) do
    case :ets.lookup(table!(opts), request_id) do
      [{^request_id, data, fingerprint, expires}] ->
        {data, fingerprint, from_unix_epoch!(expires)}

      [] ->
        :not_found
    end
  end

  @impl true
  def insert(request_id, data, fingerprint, expires_at, opts) do
    expires = to_unix_epoch(expires_at)

    case :ets.insert_new(table!(opts), {request_id, data, fingerprint, expires}) do
      true -> :ok
      false -> {:error, "key #{request_id} already exists in store"}
    end
  end

  @impl true
  def update(request_id, data, expires_at, opts) do
    expires = to_unix_epoch(expires_at)

    case :ets.update_element(table!(opts), request_id, [{2, data}, {4, expires}]) do
      true -> :ok
      false -> {:error, "key #{request_id} not found in store"}
    end
  end

  @impl true
  def prune(opts) do
    before_epoch = to_unix_epoch(DateTime.utc_now())

    :ets.select_delete(table!(opts), [
      {{:_, :_, :_, :"$1"}, [{:<, :"$1", before_epoch}], [true]}
    ])

    :ok
  end

  defp table(opts) do
    case Keyword.fetch(opts, :table) do
      {:ok, table} -> {:ok, table}
      :error -> {:error, ":table must be specified in options for #{inspect(__MODULE__)}"}
    end
  end

  defp table!(opts) do
    case table(opts) do
      {:ok, table} -> table
      {:error, error} -> raise error
    end
  end

  defp from_unix_epoch!(datetime) do
    DateTime.from_unix!(datetime, :microsecond)
  end

  defp to_unix_epoch(datetime) do
    DateTime.to_unix(datetime, :microsecond)
  end
end
