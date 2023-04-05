if Code.ensure_loaded?(Mix.Tasks.Ecto.Gen.Migration) do
defmodule Mix.Tasks.IdempotencyPlug.Ecto.Gen.Migration do
  @moduledoc """
  Generates a IdempotencyPlug store migration.

  See `Mix.Tasks.Ecto.Gen.Migration` for options, takes all options
  except `--change`.
  """
  @shortdoc "Generates a new IdempotencyPlug store migration for the repo"
  use Mix.Task

  alias Mix.Tasks.Ecto.Gen.Migration

  @impl true
  def run(args) do
    args =
      case OptionParser.parse!(args, switches: []) do
        {_, [_name | _rest]} -> Mix.raise "Do not define a table name"
        {_, []} ->  args ++ ["idempotency_plug_requests"]
      end

    if "--change" in args do
      Mix.raise "--change flag is not allowed"
    else
      change =
        """
          create table(:idempotency_plug_requests, primary_key: false) do
            add :id, :string, primary_key: true
            add :fingerprint, :string, null: false
            add :data, :binary, null: false
            add :expires_at, :utc_datetime_usec, null: false

            timestamps()
          end
        """

      Migration.run(args ++ ["--change", change])
    end
  end
end
end
