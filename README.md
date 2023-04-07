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
    {:idempotency_plug, "~> 0.1"}
  ]
end
```

## Usage

First add the request tracker to your supervision tree:

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

## Customize response

The plug handling can be customized by using the `IdempotencyPlug.Handler` behaviour:

```elixir
defmodule MyAppWeb.IdempotencyPlugHandler do
  @behaviour IdempotencyPlug.Handler

  import Phoenix.Controller
  import Plug.Conn

  @impl true
  def idempotent_id(conn, id) do
    IdempotencyPlug.Handler.idempotent_id(conn, id)
  end

  @impl true
  def resp_error(conn, error) do
    conn
    |> put_status(IdempotencyPlug.Handler.status(error))
    |> json(%{error: IdempotencyPlug.Handler.message(error)})
  end
end
```

Remember to update the plug opts:

```elixir
plug IdempotencyPlug,
  tracker: MyAppWeb.RequestTracker,
  handler: MyAppWeb.IdempotencyPlugHandler
```

## Scope `Idempotency-Key`

If you authenticate a user in your API you will need to scope the `Idempotency-Key` to the authenticated user:

```elixir
defmodule MyAppWeb.IdempotencyPlugHandler do
  @behaviour IdempotencyPlug.Handler

  @impl true
  def idempotent_id(conn, id) do
    "#{conn.assigns.current_user.id}:#{id}"
  end

  @impl true
  def resp_error(conn, error) do
    IdempotencyPlug.Handler.resp_error(conn, error)
  end
end
```

## Phoenix tests

For your controller tests you may want to add this helper to set up the idempotency key:

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
