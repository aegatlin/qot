defmodule Qot.AppleTestKeys do
  @moduledoc """
  A stand-in for Apple's Sign in with Apple keys: an RSA key made once per
  compile, published under a fixed `kid` by `fetch/0` (the key source the
  test config gives `Qot.Accounts.AppleKeys`), and helpers to sign identity
  tokens with it the way Apple does.
  """

  @behaviour Qot.Accounts.AppleKeys.Source

  @kid "test-kid"
  @client_id "llc.abstractsyntax.qot"
  {_, private} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_map()
  @private private

  def kid, do: @kid
  def client_id, do: @client_id

  def private_jwk, do: JOSE.JWK.from_map(@private)

  @doc "A different RSA key, which Apple never published."
  def other_jwk, do: JOSE.JWK.generate_key({:rsa, 2048})

  @doc "The published keys: Apple's JWKS shape, public parts only."
  @impl true
  def fetch do
    Qot.Accounts.AppleKeys.parse(%{"keys" => [public_map()]})
  end

  def public_map do
    {_, public} = private_jwk() |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Map.merge(public, %{"kid" => @kid, "alg" => "RS256", "use" => "sig"})
  end

  @doc "Claims Apple would send for `nonce` (raw), with `overrides` merged in."
  def claims(nonce, overrides \\ %{}) do
    now = System.os_time(:second)

    Map.merge(
      %{
        "iss" => "https://appleid.apple.com",
        "aud" => @client_id,
        "exp" => now + 600,
        "iat" => now,
        "sub" => "001234.abcdef.0123",
        "nonce" => hash_nonce(nonce),
        "email" => "person@example.com",
        "email_verified" => true
      },
      overrides
    )
  end

  @doc "An identity token over `claims`, signed with `:jwk` (default: the published key) under `:kid`."
  def sign(claims, opts \\ []) do
    jwk = Keyword.get(opts, :jwk, private_jwk())
    header = %{"alg" => Keyword.get(opts, :alg, "RS256"), "kid" => Keyword.get(opts, :kid, @kid)}
    {_, token} = JOSE.JWT.sign(jwk, header, claims) |> JOSE.JWS.compact()
    token
  end

  def hash_nonce(nonce), do: :crypto.hash(:sha256, nonce) |> Base.encode16(case: :lower)
end
