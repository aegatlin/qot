defmodule QotWeb.AuthController do
  use QotWeb, :controller

  require Logger

  alias Qot.Accounts

  @doc """
  POST /api/auth/device {"email": "..."}
  Starts a device sign-in and emails the link. The device shows `user_code`
  and polls `/api/auth/device/token` every `interval` seconds. Too many
  starts for one address or client IP get a 429 with `Retry-After` (and
  `retry_after` in the body), in seconds.
  """
  def start_device_login(conn, %{"email" => email}) when is_binary(email) do
    case Accounts.start_device_login(email, conn.assigns[:client_ip]) do
      {:ok, started} ->
        json(conn, started)

      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limited", retry_after: seconds})

      {:error, :invalid_email} ->
        conn |> put_status(:bad_request) |> json(%{error: "Email is invalid"})

      {:error, reason} ->
        Logger.error("device sign-in failed to start: #{inspect(reason)}")
        conn |> put_status(:internal_server_error) |> json(%{error: "Failed to start sign-in"})
    end
  end

  def start_device_login(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Email is required"})
  end

  @doc """
  POST /api/auth/device/token {"device_code": "..."}
  Tokens once the sign-in is approved; otherwise a 400 whose `error` is
  `authorization_pending` (keep polling) or why it will never succeed.
  """
  def poll_device_login(conn, %{"device_code" => device_code}) when is_binary(device_code) do
    case Accounts.poll_device_login(device_code) do
      {:ok, %{access_token: access_token, refresh_token: refresh_token, user: user}} ->
        json(conn, %{
          access_token: access_token,
          refresh_token: refresh_token,
          user: %{id: user.id, email: user.email}
        })

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: poll_error(reason)})
    end
  end

  def poll_device_login(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_device_code"})
  end

  defp poll_error(:authorization_pending), do: "authorization_pending"
  defp poll_error(:expired), do: "expired_token"
  defp poll_error(:denied), do: "access_denied"
  defp poll_error(:consumed), do: "already_used"
  defp poll_error(_), do: "invalid_device_code"

  @doc """
  POST /api/auth/refresh
  Refresh an access token using a refresh token.
  Body: {"refresh_token": "abc..."}
  """
  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Accounts.refresh_access_token(refresh_token) do
      {:ok, %{access_token: access_token}} ->
        json(conn, %{access_token: access_token})

      {:error, :invalid_or_expired_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid or expired refresh token"})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to refresh token"})
    end
  end

  def refresh(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Refresh token is required"})
  end

  @doc """
  POST /api/auth/logout
  Revoke a refresh token (logout).
  Body: {"refresh_token": "abc..."}
  """
  def logout(conn, %{"refresh_token" => refresh_token}) do
    case Accounts.revoke_refresh_token(refresh_token) do
      :ok ->
        json(conn, %{message: "Logged out successfully"})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to logout"})
    end
  end

  def logout(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Refresh token is required"})
  end
end
