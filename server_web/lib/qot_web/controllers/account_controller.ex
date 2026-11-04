defmodule QotWeb.AccountController do
  use QotWeb, :controller

  alias Qot.Accounts
  alias Qot.Accounts.SignInLimit

  @doc """
  DELETE /api/account {"confirm": "<the account's email>"}
  Deletes the signed-in account and everything the server keeps about it.
  The email must be repeated (case and surrounding space don't matter), so
  a stray or buggy request can't delete an account. Notes on the person's
  devices stay there.
  """
  def delete(conn, params) do
    user_id = conn.assigns.user_id

    with {:ok, user} <- Accounts.get_user(user_id),
         :ok <- confirm(user, params["confirm"]),
         :ok <- Accounts.delete_user(user_id) do
      # Live sockets were authorised by a token that is still valid for up
      # to an hour; close them now.
      QotWeb.Endpoint.broadcast("user:#{user_id}", "disconnect", %{})
      json(conn, %{deleted: true})
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :confirmation_mismatch} ->
        conn |> put_status(:bad_request) |> json(%{error: "confirmation_mismatch"})
    end
  end

  defp confirm(user, typed) when is_binary(typed) do
    if SignInLimit.email_key(typed) == SignInLimit.email_key(user.email),
      do: :ok,
      else: {:error, :confirmation_mismatch}
  end

  defp confirm(_user, _typed), do: {:error, :confirmation_mismatch}
end
