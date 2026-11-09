defmodule Qot.Accounts.AppleIdentity do
  @moduledoc """
  The rules of Sign in with Apple, pure
  (docs/records/2026-11-08-sign-in-with-apple.md): checking Apple's identity
  token against a key already in hand, and deciding which account it signs
  in to given what the database holds. Fetching Apple's keys is
  `Qot.Accounts.AppleKeys`; the I/O is `Qot.Accounts.sign_in_with_apple/2`.
  """

  @issuer "https://appleid.apple.com"

  @type identity :: %{
          sub: String.t(),
          email: String.t() | nil,
          email_verified: boolean(),
          client_id: String.t()
        }
  @type error ::
          :malformed
          | :bad_signature
          | :bad_issuer
          | :bad_audience
          | :expired
          | :bad_nonce
          | :bad_subject

  @doc "The `kid` in an identity token's header: which of Apple's keys signed it."
  @spec kid(String.t()) :: {:ok, String.t()} | {:error, :malformed}
  def kid(token) do
    with {:ok, header} <- protected_header(token),
         %{"kid" => kid} when is_binary(kid) <- header do
      {:ok, kid}
    else
      _ -> {:error, :malformed}
    end
  end

  defp protected_header(token) do
    case token |> JOSE.JWS.peek_protected() |> Jason.decode() do
      {:ok, %{} = header} -> {:ok, header}
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  @doc """
  Checks an identity token: an RS256 signature by `jwk`, issued by Apple for
  one of `client_ids`, not expired at `now` (Unix seconds), and carrying the
  SHA-256 (lowercase hex) of `raw_nonce`, which the app sent with its request
  to Apple. Returns who it is.
  """
  @spec verify(String.t(), JOSE.JWK.t(), String.t(), [String.t()], integer()) ::
          {:ok, identity()} | {:error, error()}
  def verify(token, jwk, raw_nonce, client_ids, now) do
    with {:ok, _header} <- protected_header(token),
         {:ok, claims} <- verify_signature(token, jwk) do
      check_claims(claims, raw_nonce, client_ids, now)
    end
  end

  defp verify_signature(token, jwk) do
    case JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _ -> {:error, :bad_signature}
    end
  rescue
    _ -> {:error, :malformed}
  end

  @doc "The claim checks of `verify/5`, on claims whose signature is checked."
  @spec check_claims(map(), String.t(), [String.t()], integer()) ::
          {:ok, identity()} | {:error, error()}
  def check_claims(claims, raw_nonce, client_ids, now) do
    cond do
      claims["iss"] != @issuer -> {:error, :bad_issuer}
      not audience_allowed?(claims["aud"], client_ids) -> {:error, :bad_audience}
      not (is_integer(claims["exp"]) and claims["exp"] > now) -> {:error, :expired}
      not nonce_matches?(claims["nonce"], raw_nonce) -> {:error, :bad_nonce}
      not (is_binary(claims["sub"]) and claims["sub"] != "") -> {:error, :bad_subject}
      true -> {:ok, identity(claims, client_ids)}
    end
  end

  defp audience_allowed?(aud, client_ids) when is_binary(aud), do: aud in client_ids

  defp audience_allowed?(aud, client_ids) when is_list(aud),
    do: Enum.any?(aud, &(&1 in client_ids))

  defp audience_allowed?(_aud, _client_ids), do: false

  defp nonce_matches?(claimed, raw_nonce) when is_binary(claimed) do
    expected = :crypto.hash(:sha256, raw_nonce) |> Base.encode16(case: :lower)
    byte_size(claimed) == byte_size(expected) and :crypto.hash_equals(claimed, expected)
  end

  defp nonce_matches?(_claimed, _raw_nonce), do: false

  # Apple sends email_verified as a boolean or as the string "true".
  # `client_id` is the audience it was issued to (the app, or later the web).
  defp identity(claims, client_ids) do
    email = if is_binary(claims["email"]) and claims["email"] != "", do: claims["email"]

    %{
      sub: claims["sub"],
      email: email,
      email_verified: email != nil and claims["email_verified"] in [true, "true"],
      client_id: claims["aud"] |> List.wrap() |> Enum.find(&(&1 in client_ids))
    }
  end

  @doc """
  Which account an Apple identity signs in to, given the user already linked
  to its `sub` (`by_sub`) and the user whose email matches its email,
  ignoring case (`by_email`), each `nil` when there is none:

  - `{:existing, user}`: the user linked to this Apple account.
  - `{:link, user}`: the account with the same verified email, to be linked.
  - `{:create, attrs}`: a new account with the email, linked.
  - `{:error, :email_in_use}`: the email belongs to an account that can't be
    linked (the email isn't verified, or the account is linked to another
    Apple account).
  - `{:error, :no_email}`: no linked account and no email to make one with.
  """
  @spec account(identity(), user, user) ::
          {:existing, user}
          | {:link, user}
          | {:create, %{email: String.t(), apple_sub: String.t()}}
          | {:error, :email_in_use | :no_email}
        when user: map() | nil
  def account(_identity, by_sub, _by_email) when by_sub != nil, do: {:existing, by_sub}
  def account(%{email: nil}, nil, _by_email), do: {:error, :no_email}

  def account(%{sub: sub, email: email}, nil, nil), do: {:create, %{email: email, apple_sub: sub}}

  def account(%{email_verified: true}, nil, %{apple_sub: nil} = user), do: {:link, user}
  def account(_identity, nil, _by_email), do: {:error, :email_in_use}
end
