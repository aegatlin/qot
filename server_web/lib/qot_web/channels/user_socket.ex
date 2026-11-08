defmodule QotWeb.UserSocket do
  use Phoenix.Socket

  alias Qot.Accounts
  alias Qot.Accounts.Token

  # Channel routes
  channel("notes:user:*", QotWeb.NotesChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # A deleted account's token is still valid for up to an hour; refuse it.
    with {:ok, %{"user_id" => user_id}} <- Token.verify_jwt(token),
         true <- Accounts.user_exists?(user_id) do
      {:ok, assign(socket, :user_id, user_id)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    # Reject connection if no token provided
    :error
  end

  @impl true
  def id(socket), do: "user:#{socket.assigns.user_id}"
end
