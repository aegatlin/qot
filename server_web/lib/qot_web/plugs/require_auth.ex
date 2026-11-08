defmodule QotWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug to require JWT authentication for protected routes.
  Extracts and verifies the JWT from the Authorization header, and checks
  that its user still exists: a deleted account's tokens stay valid until
  they expire, and its devices should get 401 (signed out) meanwhile.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Qot.Accounts
  alias Qot.Accounts.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Token.verify_jwt(token),
         %{"user_id" => user_id} <- claims,
         true <- Accounts.user_exists?(user_id) do
      assign(conn, :user_id, user_id)
    else
      _ ->
        # Authentication failed
        conn
        |> put_status(:unauthorized)
        |> put_view(json: QotWeb.ErrorJSON)
        |> render(:"401")
        |> halt()
    end
  end
end
