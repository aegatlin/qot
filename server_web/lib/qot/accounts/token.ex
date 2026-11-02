defmodule Qot.Accounts.Token do
  @moduledoc """
  Utilities for generating and verifying JWT access tokens and other auth tokens.
  """

  use Joken.Config

  # 1 hour in seconds
  @access_token_ttl 60 * 60
  # 30 days in seconds
  @refresh_token_ttl 60 * 60 * 24 * 30

  @doc """
  Generates a JWT access token for the given user_id.
  Default expiration: 1 hour
  """
  def generate_jwt(user_id) do
    extra_claims = %{
      "user_id" => user_id,
      "exp" =>
        DateTime.utc_now() |> DateTime.add(@access_token_ttl, :second) |> DateTime.to_unix()
    }

    generate_and_sign(extra_claims)
  end

  @doc """
  Verifies and decodes a JWT access token.
  Returns {:ok, claims} or {:error, reason}
  """
  def verify_jwt(token) do
    verify_and_validate(token)
  end

  @doc """
  Generates a cryptographically secure random token (refresh tokens,
  device codes and sign-in links).
  Returns a 32-byte base64-encoded string.
  """
  def generate_refresh_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc """
  Hashes a token using SHA256 for secure storage in database.
  """
  def hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode64()
  end

  @doc """
  Returns the refresh token TTL in seconds.
  """
  def refresh_token_ttl, do: @refresh_token_ttl

  @doc """
  Calculates expiration datetime for refresh tokens.
  """
  def refresh_token_expires_at do
    DateTime.utc_now() |> DateTime.add(@refresh_token_ttl, :second)
  end
end
