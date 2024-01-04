defmodule IdempotencyPlug.RequestTracker do
  @moduledoc """
  A GenServer that tracks processes to ensure requests, at most, are processed
  once.

  ### Storage

  First-time tracked request will store `{:processing, {node, pid}}` request
  state with an expiration date for the provided request ID. Once the request
  has completed, `put_response/3` must be called to update the cached response.
  The response will be stored as `{:ok, data}` with an expiration date.

  The process for a tracked request may halt unexpectedly (e.g. due to raised
  exception). This module will track the terminated process and store the value as
  `{:halted, reason}`.

  All cached responses will be removed after 24 hours.

  ### Lookup

  For subsequent requests, the state of the first-time tracked request will be
  returned in the format of `{:cache, {:ok, data}, expires_at}`.

  If the request payload fingerprint differs,
  `{:mismatch, {:fingerprint, fingerprint}, expires_at}` is returned.

  If first-time request has not yet completed,
  `{:processing, {node, pid}, expires_at}` is returned.

  If the request unexpectedly terminated,
  `{:cache, {:halted, reason}, expires_at}` is returned.

  ## Options

    * `:cache_ttl` - the TTL in milliseconds for any objects in the cache
      store. Defaults to 24 hours.

    * `:prune` - the interval in milliseconds to prune the cache store for
      expired objects. Defaults to 60 seconds.

    * `:store` - the cache store module to use to store the cache objects.
      Defaults to `{IdempotencyPlug.ETSStore, [table: #{__MODULE__}]}`.

  ## Examples

      children = [
        {
          IdempotencyPlug.RequestTracker,
            cache_ttl: :timer.hours(6),
            prune: :timer.minutes(1),
            store: {IdempotencyPlug.EctoStore, repo: MyApp.Repo}
        }
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  """
  use GenServer

  alias IdempotencyPlug.ETSStore

  @cache_ttl :timer.hours(24)
  @prune :timer.seconds(60)

  ## API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    opts = Keyword.merge([cache_ttl: @cache_ttl, prune: @prune], opts)

    store =
      case opts[:store] do
        nil -> {ETSStore, [table: __MODULE__]}
        {mod, opts} -> {mod, opts}
        mod -> {mod, []}
      end

    opts = Keyword.put(opts, :store, store)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Tracks a request ID.

  This function will return `{:init, key, expires_at}` for first-time requests.
  Subsequent requests will return the request state. If the request payload
  fingerprint differs from what was stored, an error is returned.
  """
  @spec track(atom() | pid(), binary(), binary()) ::
          {:error, term()}
          | {:init, binary(), DateTime.t()}
          | {:mismatch, {:fingerprint, binary()}, DateTime.t()}
          | {:processing, {atom(), pid()}, DateTime.t()}
          | {:cache, {:ok, any()}, DateTime.t()}
          | {:cache, {:halted, term()}, DateTime.t()}
  def track(name_or_pid, request_id, fingerprint) do
    GenServer.call(name_or_pid, {:track, request_id, fingerprint})
  end

  @doc """
  Updates the state for a given request ID.
  """
  @spec put_response(atom() | pid(), binary(), any()) :: {:ok, DateTime.t()} | {:error, term()}
  def put_response(name_or_pid, request_id, response) do
    GenServer.call(name_or_pid, {:put_response, request_id, response})
  end

  ## Callbacks

  @impl true
  def init(opts) do
    {store, store_opts} = fetch_store(opts)

    case store.setup(store_opts) do
      :ok ->
        Process.send_after(self(), :prune, Keyword.fetch!(opts, :prune))
        {:ok, %{monitored: [], options: opts}}

      {:error, error} ->
        {:stop, error}
    end
  end

  defp fetch_store(opts) do
    {store, store_opts} = Keyword.fetch!(opts, :store)

    {opts, _} = Keyword.split(opts, [:cache_ttl])

    {store, Keyword.merge(store_opts, opts)}
  end

  @impl true
  def handle_call({:track, request_id, fingerprint}, {caller, _}, state) do
    {store, store_opts} = fetch_store(state.options)

    case store.lookup(request_id, store_opts) do
      :not_found ->
        data = {:processing, {Node.self(), caller}}
        expires_at = expires_at(state.options)

        case store.insert(request_id, data, fingerprint, expires_at, store_opts) do
          :ok ->
            {:reply, {:init, request_id, expires_at}, put_monitored(state, request_id, caller)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {{:processing, node_caller}, ^fingerprint, expires} ->
        {:reply, {:processing, node_caller, expires}, state}

      {{:halted, reason}, ^fingerprint, expires} ->
        {:reply, {:cache, {:halted, reason}, expires}, state}

      {{:ok, response}, ^fingerprint, expires} ->
        {:reply, {:cache, {:ok, response}, expires}, state}

      {_res, other_fingerprint, expires} ->
        {:reply, {:mismatch, {:fingerprint, other_fingerprint}, expires}, state}
    end
  end

  def handle_call({:put_response, request_id, response}, _from, state) do
    {store, store_opts} = fetch_store(state.options)
    {_finished, state} = pop_monitored(state, &(elem(&1, 0) == request_id))
    data = {:ok, response}
    expires_at = expires_at(state.options)

    case store.update(request_id, data, expires_at, store_opts) do
      :ok -> {:reply, {:ok, expires_at}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp put_monitored(state, request_id, caller) do
    ref = Process.monitor(caller)

    %{state | monitored: state.monitored ++ [{request_id, caller, ref}]}
  end

  defp pop_monitored(state, fun) do
    {finished, monitored} = Enum.split_with(state.monitored, fn track -> fun.(track) end)

    Enum.each(finished, fn {_request_id, _caller, ref} -> Process.demonitor(ref) end)

    {finished, %{state | monitored: monitored}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    {store, store_opts} = fetch_store(state.options)
    {finished, state} = pop_monitored(state, &(elem(&1, 1) == pid))
    data = {:halted, reason}
    expires_at = expires_at(state.options)

    Enum.each(finished, &store.update(elem(&1, 0), data, expires_at, store_opts))

    {:noreply, state}
  end

  def handle_info(:prune, state) do
    {store, store_opts} = fetch_store(state.options)

    store.prune(store_opts)

    Process.send_after(self(), :prune, Keyword.fetch!(state.options, :prune))

    {:noreply, state}
  end

  defp expires_at(opts) do
    DateTime.add(DateTime.utc_now(), Keyword.fetch!(opts, :cache_ttl), :millisecond)
  end
end
