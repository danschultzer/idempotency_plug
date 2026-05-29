defmodule IdempotencyPlug.Store do
  @moduledoc ~S"""
  Behaviour for cache stores.

  Callbacks are invoked from `IdempotencyPlug.RequestTracker`.

  ## Examples

      defmodule RedixStore do
        @behaviour IdempotencyPlug.Store

        @impl true
        def setup(options) do
          name = Keyword.fetch!(options, :redix)

          {:ok, _conn} = Redix.start_link(name: name)

          :ok
        end

        @impl true
        def lookup(request_id, options) do
          redix = Keyword.fetch!(options, :redix)

          case Redix.command(redix, ["GET", request_id]) do
            {:ok, nil} ->
              :not_found

            {:ok, encoded} ->
              {data, fingerprint, expires_at} = :erlang.binary_to_term(encoded, [:safe])

              {data, fingerprint, expires_at}

            {:error, reason} ->
              raise reason
          end
        end

        @impl true
        def insert(request_id, data, fingerprint, expires_at, options) do
          redix = Keyword.fetch!(options, :redix)
          value = :erlang.term_to_binary({data, fingerprint, expires_at})
          expires_in = DateTime.diff(expires_at, DateTime.utc_now(), :second)

          case Redix.command(redix, ["SET", request_id, value, "EX", Integer.to_string(expires_in), "NX"]) do
            {:ok, "OK"} ->
              :ok

            {:ok, nil} ->
              {:error, "key #{request_id} already exists in store"}

            {:error, reason} ->
              {:error, reason}
          end
        end

        @impl true
        def update(request_id, data, expires_at, options) do
          redix = Keyword.fetch!(options, :redix)

          case lookup(request_id, options) do
            :not_found ->
              {:error, "key #{request_id} not found in store"}

            {_data, fingerprint, _expires_at} ->
              value = :erlang.term_to_binary({data, fingerprint, expires_at})
              expires_in = DateTime.diff(expires_at, DateTime.utc_now(), :second)

              case Redix.command(redix, ["SET", request_id, value, "EX", Integer.to_string(expires_in)]) do
                {:ok, "OK"} -> :ok
                {:error, reason} -> {:error, reason}
              end
          end
        end

        @impl true
        def prune(options), do: :ok
      end
  """
  @type options :: keyword()
  @type request_id :: binary()
  @type fingerprint :: binary()
  @type data :: term()
  @type expires_at :: DateTime.t()

  @doc """
  Initializes the store.

  Called once when `IdempotencyPlug.RequestTracker` starts. Use this to
  prepare the store for use, e.g. create table or verify database connection.

  Returns `{:error, reason}` if initialization fails, which will cause
  `IdempotencyPlug.RequestTracker` to fail to start.
  """
  @callback setup(options()) :: :ok | {:error, term()}

  @doc """
  Fetches the entry for `t:request_id/0`.

  Returns a tuple of `t:data/0`, `t:fingerprint/0`, and `t:expires_at/0` that
  was inserted in `c:insert/5` or updated in `c:update/4`. Returns `:not_found`
  if no entry exists.
  """
  @callback lookup(request_id(), options()) :: {data(), fingerprint(), expires_at()} | :not_found

  @doc """
  Inserts a new entry for `t:request_id/0`.

  Returns `{:error, reason}` if an entry already exists for `t:request_id/0`, or
  if any other error occurs.
  """
  @callback insert(request_id(), data(), fingerprint(), expires_at(), options()) ::
              :ok | {:error, term()}

  @doc """
  Updates the entry for `t:request_id/0`.

  Returns `{:error, reason}` if no entry exists for `t:request_id/0`, or if any
  other error occurs.
  """
  @callback update(request_id(), data(), expires_at(), options()) :: :ok | {:error, term()}

  @doc """
  Deletes expired entries.

  Called periodically by `IdempotencyPlug.RequestTracker` per its `:prune`
  option.
  """
  @callback prune(options()) :: :ok
end
