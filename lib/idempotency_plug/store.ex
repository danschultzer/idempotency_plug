defmodule IdempotencyPlug.Store do
  @moduledoc """
  Module that defines the store callbacks.

  ## Examples

      defmodule CustomStore do
        @behaviour IdempotencyPlug.Store

        @impl true
        def setup(options)

        @impl true
        def lookup(request_id, options)

        @impl true
        def insert(request_id, fingerprint, data, options)

        @impl true
        def update(request_id, data, options)

        @impl true
        def prune(options)
      end
  """
  @type options :: keyword()
  @type request_id :: binary()
  @type fingerprint :: binary()
  @type data :: term()
  @type expires_at :: DateTime.t()

  @callback setup(options()) :: :ok | {:error, term()}
  @callback lookup(request_id(), options()) :: {data(), fingerprint(), expires_at()} | :not_found
  @callback insert(request_id(), data(), fingerprint(), expires_at(), options()) ::
              :ok | {:error, term()}
  @callback update(request_id(), data(), expires_at(), options()) :: :ok | {:error, term()}
  @callback prune(options()) :: :ok
end
