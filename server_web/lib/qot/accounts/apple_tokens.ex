defmodule Qot.Accounts.AppleTokens do
  @moduledoc """
  Apple's token endpoints, for revoking Sign in with Apple when an account
  is deleted (App Review Guideline 5.1.1(v); #88). A sign-in's one-time
  authorization code is exchanged for Apple's refresh token, which the user
  row keeps; deleting the account revokes it.

  Both calls authenticate with a client secret: a short-lived ES256 JWT
  signed with the Sign in with Apple key (`APPLE_SIWA_KEY`,
  `APPLE_SIWA_KEY_ID`; `config :qot, :apple_signing_key`). Building it and
  reading Apple's answer are pure; the HTTP is `Qot.Accounts.AppleTokens.Apple`
  (config `:qot, :apple_tokens_api`; tests use `Qot.AppleTestTokens`).
  """

  @audience "https://appleid.apple.com"
  @secret_ttl 300

  @type key :: %{team_id: String.t(), key_id: String.t(), pem: String.t()}

  defmodule API do
    @moduledoc "Apple's `/auth/token` (code exchange) and `/auth/revoke`."
    @callback exchange(client_id :: String.t(), code :: String.t()) ::
                {:ok, refresh_token :: String.t()} | {:error, term()}
    @callback revoke(client_id :: String.t(), refresh_token :: String.t()) ::
                :ok | {:error, term()}
  end

  @doc "Exchanges a sign-in's authorization code for Apple's refresh token."
  def exchange(client_id, code), do: api().exchange(client_id, code)

  @doc "Revokes a refresh token, ending the app's Sign in with Apple link."
  def revoke(client_id, refresh_token), do: api().revoke(client_id, refresh_token)

  defp api, do: Application.get_env(:qot, :apple_tokens_api, __MODULE__.Apple)

  @doc "The private key in `key.pem` (Apple's .p8), or `{:error, :bad_key}`."
  @spec signing_key(key()) :: {:ok, JOSE.JWK.t()} | {:error, :bad_key}
  def signing_key(%{pem: pem}) when is_binary(pem) do
    case JOSE.JWK.from_pem(pem) do
      %JOSE.JWK{} = jwk -> {:ok, jwk}
      _ -> {:error, :bad_key}
    end
  rescue
    _ -> {:error, :bad_key}
  end

  def signing_key(_key), do: {:error, :bad_key}

  @doc """
  The client secret for `client_id` at `now` (Unix seconds): an ES256 JWT
  from the team, for Apple, valid five minutes. `key` must be valid
  (`signing_key/1`).
  """
  @spec client_secret(String.t(), key(), integer()) :: String.t()
  def client_secret(client_id, key, now) do
    {:ok, jwk} = signing_key(key)

    claims = %{
      "iss" => key.team_id,
      "sub" => client_id,
      "aud" => @audience,
      "iat" => now,
      "exp" => now + @secret_ttl
    }

    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => key.key_id}, claims)
      |> JOSE.JWS.compact()

    token
  end

  @doc "The refresh token in Apple's `/auth/token` response."
  @spec refresh_token(term()) :: {:ok, String.t()} | {:error, :no_refresh_token}
  def refresh_token(%{"refresh_token" => token}) when is_binary(token) and token != "",
    do: {:ok, token}

  def refresh_token(_body), do: {:error, :no_refresh_token}

  defmodule Apple do
    @moduledoc "Apple's token endpoints, over HTTP."
    @behaviour Qot.Accounts.AppleTokens.API

    alias Qot.Accounts.AppleTokens

    @base "https://appleid.apple.com/auth"

    @impl true
    def exchange(client_id, code) do
      with {:ok, secret} <- secret(client_id),
           {:ok, body} <-
             post("/token",
               client_id: client_id,
               client_secret: secret,
               code: code,
               grant_type: "authorization_code"
             ) do
        AppleTokens.refresh_token(body)
      end
    end

    @impl true
    def revoke(client_id, refresh_token) do
      with {:ok, secret} <- secret(client_id),
           {:ok, _body} <-
             post("/revoke",
               client_id: client_id,
               client_secret: secret,
               token: refresh_token,
               token_type_hint: "refresh_token"
             ) do
        :ok
      end
    end

    defp secret(client_id) do
      case Application.get_env(:qot, :apple_signing_key) do
        nil ->
          {:error, :not_configured}

        key ->
          with {:ok, _jwk} <- AppleTokens.signing_key(key) do
            {:ok, AppleTokens.client_secret(client_id, key, System.os_time(:second))}
          end
      end
    end

    # Apple's errors are JSON like {"error": "invalid_grant"}; never log the form.
    defp post(path, form) do
      case Req.post(@base <> path, form: form, receive_timeout: 5_000, retry: false) do
        {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
        {:ok, %Req.Response{status: status, body: %{"error" => e}}} -> {:error, {status, e}}
        {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
