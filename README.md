# IdempotencyPlug

[![Github CI](https://github.com/danschultzer/idempotency_plug/workflows/CI/badge.svg)](https://github.com/danschultzer/idempotency_plug/actions?query=workflow%3ACI)
[![hex.pm](https://img.shields.io/hexpm/v/idempotency_plug.svg)](https://hex.pm/packages/idempotency_plug)

<!-- MDOC !-->

Plug that makes POST and PATCH requests idempotent using `Idempotency-Key` HTTP header.

Follows the [IETF Idempotency-Key HTTP Header Field specification draft](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/).

<!-- MDOC !-->

## Installation

Add `idempotency_plug` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:idempotency_plug, "~> 0.2"}
  ]
end
```

## Usage

First, add the request tracker to your supervision tree:

```elixir
defmodule MyApp.Application do
  # ..

  def start(_type, _args) do
    children = [
      {IdempotencyPlug.RequestTracker, [name: MyAppWeb.RequestTracker]}
      # ...
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

Now add the plug to your pipeline:

```elixir
defmodule MyAppWeb.Router do
  # ...

  pipeline :api do
    plug :accepts, ["json"]
    plug IdempotencyPlug, tracker: MyAppWeb.RequestTracker
  end

  # ...
end
```

All POST and PATCH requests will now be idempotent using the `Idempotency-Key` HTTP header value, storing responses with the default ETS store.

### Persisted store

The ETS store is not persisted, so it's not production ready. Instead, let's change the store to use Ecto.

First, run `mix idempotency_plug.ecto.gen.migration`.

Now update the configuration for the request tracker:

```elixir
{IdempotencyPlug.RequestTracker, [store: {IdempotencyPlug.EctoStore, repo: MyApp.Repo}]}
```

You can also implement your own idempotent request store by using the behaviour in `IdempotencyPlug.Store`.

## Scope `Idempotency-Key`

If you are authenticating users then you must scope the `Idempotency-Key` to the authenticated user:

```elixir
plug IdempotencyPlug,
  tracker: MyAppWeb.RequestTracker,
  idempotency_key: {__MODULE__, :scope_idempotency_key}

def scope_idempotency_key(conn, key), do: {conn.assigns.current_user.id, key}
```

Otherwise, you may have a security vulnerability (or conflict) where any user can access another user's cached responses when requests are identical.

## Customize error response

By default, errors are raised and handled by the `Plug.Exception` protocol, but you can handle the errors by setting the `:with` option:

```elixir
plug IdempotencyPlug,
  tracker: MyAppWeb.RequestTracker,
  with: {__MODULE__, :handle_error}

def handle_error(conn, error) do
  conn
  |> put_status(Plug.Exception.Handler.status(error))
  |> json(%{error: error.message})
  |> halt()
end
```

## Phoenix tests

For your controller tests, you may want to add this helper to set up the idempotency key:

```elixir
def setup_with_idempotency_key(%{conn: conn}) do
  conn = Plug.Conn.put_req_header(conn, "idempotency-key", Ecto.UUID.bingenerate())

  {:ok, conn: conn}
end
```

```elixir
setup :setup_with_idempotency_key
```

This ensures that all the tests succeed by generating a UUID for all requests.

<!-- MDOC !-->

## LICENSE

(The MIT License)

Copyright (c) 2023 Dan Schultzer & the Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the 'Software'), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
