if Code.ensure_loaded?(Ecto) do
  defmodule IdempotencyPlug.EctoStore do
    @moduledoc """
    Module that defines an Ecto store.

    A migration file should be generated with
    `mix idempotency_plug.ecto.gen.migration`.

    ## Examples

        defmodule MyApp.Application do
          # ..

          def start(_type, _args) do
            children = [
              {IdempotencyPlug.RequestTracker, [
                store: {IdempotencyPlug.EctoStore, repo: MyApp.Repo}]}
              # ...
            ]

            Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
          end
        end
    """

    defmodule ErlangTerm do
      @moduledoc false
      use Ecto.Type

      @impl true
      def type, do: :binary

      @impl true
      def cast(term), do: {:ok, term}

      @impl true
      def load(bin) when is_binary(bin), do: {:ok, :erlang.binary_to_term(bin)}

      @impl true
      def dump(term), do: {:ok, :erlang.term_to_binary(term)}
    end

    defmodule IdempotentRequest do
      @moduledoc false
      use Ecto.Schema

      import Ecto.Changeset

      @primary_key {:id, :string, autogenerate: false}
      @timestamps_opts [type: :utc_datetime_usec]

      schema "idempotency_plug_requests" do
        field(:fingerprint, :string)
        field(:data, ErlangTerm)
        field(:expires_at, :utc_datetime_usec)

        timestamps()
      end

      def changeset(struct) do
        struct
        |> change()
        |> unique_constraint(:id, name: :idempotency_plug_requests_pkey)
      end
    end

    @behaviour IdempotencyPlug.Store

    import Ecto.Query

    @impl true
    def setup(opts) do
      case repo(opts) do
        {:ok, repo} ->
          # This will raise an error if the migration haven't been generate
          # for the repo
          repo.exists?(IdempotentRequest)

          :ok

        {:error, error} ->
          {:error, error}
      end
    end

    @impl true
    def lookup(request_id, opts) do
      case repo!(opts).get(IdempotentRequest, request_id) do
        nil -> :not_found
        request -> {request.data, request.fingerprint, request.expires_at}
      end
    end

    @impl true
    def insert(request_id, data, fingerprint, expires_at, opts) do
      changeset =
        IdempotentRequest.changeset(%IdempotentRequest{
          id: request_id,
          data: data,
          fingerprint: fingerprint,
          expires_at: expires_at
        })

      case repo!(opts).insert(changeset) do
        {:ok, _} -> :ok
        {:error, error} -> {:error, error}
      end
    end

    @impl true
    def update(request_id, data, expires_at, opts) do
      repo = repo!(opts)
      updates = [set: [data: data, expires_at: expires_at, updated_at: DateTime.utc_now()]]

      IdempotentRequest
      |> where(id: ^request_id)
      |> repo.update_all(updates)
      |> case do
        {1, _} -> :ok
        {0, _} -> {:error, "key #{request_id} not found in store"}
      end
    end

    @impl true
    def prune(opts) do
      repo = repo!(opts)

      IdempotentRequest
      |> where([r], r.expires_at < ^DateTime.utc_now())
      |> repo.delete_all()

      :ok
    end

    defp repo(opts) do
      case Keyword.fetch(opts, :repo) do
        {:ok, repo} -> {:ok, repo}
        :error -> {:error, ":repo must be specified in options for #{inspect(__MODULE__)}"}
      end
    end

    defp repo!(opts) do
      case repo(opts) do
        {:ok, repo} -> repo
        {:error, error} -> raise error
      end
    end
  end
end
