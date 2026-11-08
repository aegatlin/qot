defmodule QotWeb.AuthController do
  use QotWeb, :controller

  require Logger

  alias Qot.Accounts

  @doc """
  POST /api/auth/device {"email": "..."}
  Starts a device sign-in and emails the link. The device shows `user_code`
  and polls `/api/auth/device/token` every `interval` seconds. `app_url` is
  the web app (null without one), which the device can point to. Too many
  starts for one address or client IP get a 429 with `Retry-After` (and
  `retry_after` in the body), in seconds.
  """
  def start_device_login(conn, %{"email" => email}) when is_binary(email) do
    case Accounts.start_device_login(email, conn.assigns[:client_ip]) do
      # app_url: where the device can point the person next (the PWA).
      {:ok, started} ->
        json(conn, Map.put(started, :app_url, QotWeb.AppOrigin.url()))

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

  @doc """
  GET /api/auth/device/link?token=...
  For the PWA's sign-in page: whether an emailed link can still be used, and
  which account it signs in to. Approves nothing.
  """
  def device_link(conn, %{"token" => token}) when is_binary(token) do
    case Accounts.get_device_login_by_link(token) do
      {:ok, login} -> json(conn, %{email: login.email})
      {:error, reason} -> link_error(conn, reason)
    end
  end

  def device_link(conn, _params), do: link_error(conn, :not_found)

  @doc """
  POST /api/auth/device/approve {"token", "user_code", "sign_in_browser"}
  The PWA's sign-in page: a correct code approves the device that asked and,
  unless `sign_in_browser` is false, returns tokens for this browser too
  (docs/records/2026-11-06-sign-in-through-the-pwa.md). A wrong code is a 422
  `mismatch` and counts towards the five allowed; a used, denied or expired
  link is a 410 or 404.
  """
  def approve_device_login(conn, %{"token" => token, "user_code" => code} = params)
      when is_binary(token) and is_binary(code) do
    result =
      if params["sign_in_browser"] == false,
        do: Accounts.approve_device_login(token, code),
        else: Accounts.approve_device_login_and_sign_in(token, code)

    case result do
      {:ok, %{access_token: access_token, refresh_token: refresh_token, user: user}} ->
        json(conn, %{
          access_token: access_token,
          refresh_token: refresh_token,
          user: %{id: user.id, email: user.email}
        })

      {:ok, _login} ->
        json(conn, %{approved: true})

      {:error, :mismatch} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "mismatch"})

      {:error, reason} ->
        link_error(conn, reason)
    end
  end

  def approve_device_login(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "token and user_code are required"})
  end

  @doc """
  POST /api/auth/apple {"identity_token", "nonce"}
  Sign in with Apple (docs/records/2026-11-08-sign-in-with-apple.md): Apple's
  identity token and the raw nonce the app sent to Apple. Returns the same
  tokens as a device sign-in. An identity token that fails any check is a 401
  `invalid_token`; an email that belongs to an account it can't be linked to
  is a 409 `email_in_use`; no linked account and no email is a 422
  `email_required`; Apple's keys out of reach is a 503.
  """
  def sign_in_with_apple(conn, %{"identity_token" => token, "nonce" => nonce})
      when is_binary(token) and is_binary(nonce) do
    case Accounts.sign_in_with_apple(token, nonce) do
      {:ok, %{access_token: access_token, refresh_token: refresh_token, user: user}} ->
        json(conn, %{
          access_token: access_token,
          refresh_token: refresh_token,
          user: %{id: user.id, email: user.email}
        })

      {:error, :invalid_token} ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid_token"})

      {:error, :email_in_use} ->
        conn |> put_status(:conflict) |> json(%{error: "email_in_use"})

      {:error, :no_email} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "email_required"})

      {:error, :keys_unavailable} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "apple_unavailable"})

      {:error, reason} ->
        Logger.error("Sign in with Apple failed: #{inspect(reason)}")
        conn |> put_status(:internal_server_error) |> json(%{error: "Failed to sign in"})
    end
  end

  def sign_in_with_apple(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "identity_token and nonce are required"})
  end

  # :not_found and :expired look the same: the link can't be used.
  defp link_error(conn, reason) when reason in [:approved, :consumed, :denied] do
    conn |> put_status(:gone) |> json(%{error: Atom.to_string(reason)})
  end

  defp link_error(conn, _reason) do
    conn |> put_status(:not_found) |> json(%{error: "expired"})
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
