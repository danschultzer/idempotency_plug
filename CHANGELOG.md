## v0.2.0 (TBA)

**This is a breaking release.**

If you have been using the Idempotency.Handler behaviour, change your plug to this:

```elixir
plug IdempotencyPlug,
  tracker: MyAppWeb.RequestTracker,
  idempotency_key: {MyAppWeb.IdempotencyPlugHandler, :scope_idempotency_key},
  with: {MyAppWeb.IdempotencyPlugHandler, :handle_error}
```

And change your handler module to this:

```elixir
defmodule MyAppWeb.IdempotencyPlugHandler do
  import Phoenix.Controller
  import Plug.Conn

  def scope_idempotency_key(conn, key), do: {conn.assigns.current_user.id, key}

  def handle_error(conn, error) do
    conn
    |> put_status(Plug.Exception.status(error))
    |> json(%{error: error.message})
    |> halt()
  end
end
```

### Changes

- IdempotencyPlug.Handler removed
- IdempotencyPlug raises errors by default
- IdempotencyPlug now accepts `:idempotency_key`, `:request_payload`, `:hash`, and `:with` options
- IdempotencyPlug now requires `:tracker` option
- SHA256 hashing now accepts Erlang terms instead of just binary

## v0.1.2 (2023-04-07)

- Fix source url and name in docs

## v0.1.1 (2023-04-07)

- Fix indention for generated Ecto migration

## v0.1.0 (2023-04-06)

- Initial release
