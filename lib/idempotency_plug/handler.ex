defmodule IdempotencyPlug.Handler do
  @moduledoc """
  Module that defines the plug handler callbacks.

  ## Examples

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
  """
  alias Plug.Conn

  @type request_id :: binary()
  @type error :: :multiple_headers | :no_headers | :concurrent_request | :fingerprint_mismatch | :halted

  @callback idempotent_id(Conn.t(), request_id()) :: term()
  @callback resp_error(Conn.t(), error()) :: Conn.t()

  @doc """
  Returns the request ID as-is.
  """
  def idempotent_id(_conn, id), do: id

  @doc """
  Updates the conn with a JSON encoded response body and status code.
  """
  def resp_error(conn, error) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.resp(status(error), Jason.encode!(%{message: message(error)}))
  end

  @doc """
  Returns message for the error atom.
  """
  @spec message(error()) :: binary()
  def message(:multiple_headers), do: "Only one `Idempotency-Key` header can be sent."
  def message(:no_headers), do: "No idempotency key found. You need to set the `Idempotency-Key` header for all POST requests: 'Idempotency-Key: KEY'"
  def message(:concurrent_request), do: "A request with the same `Idempotency-Key` is currently being processed."
  def message(:fingerprint_mismatch), do: "This `Idempotency-Key` can't be reused with a different payload or URI."
  def message(:halted), do: "The original request was interrupted and can't be recovered as it's in an unknown state."

  @doc """
  Returns the status for the error atom.
  """
  @spec status(error()) :: integer()
  def status(:multiple_headers), do: 400
  def status(:no_headers), do: 400
  def status(:concurrent_request), do: 409
  def status(:fingerprint_mismatch), do: 422
  def status(:halted), do: 500
end
