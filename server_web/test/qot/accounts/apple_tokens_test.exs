defmodule Qot.Accounts.AppleTokensTest do
  use ExUnit.Case, async: true

  alias Qot.Accounts.AppleTokens

  # An EC P-256 key like the .p8 Apple hands out.
  setup do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = JOSE.JWK.to_pem(jwk)
    key = %{team_id: "TEAM123456", key_id: "KEY1234567", pem: pem}
    %{jwk: jwk, key: key}
  end

  test "the client secret is an ES256 JWT Apple can check with our key", %{jwk: jwk, key: key} do
    secret = AppleTokens.client_secret("llc.abstractsyntax.qot", key, 1_800_000_000)

    public = JOSE.JWK.to_public(jwk)

    assert {true, %JOSE.JWT{fields: claims}, jws} =
             JOSE.JWT.verify_strict(public, ["ES256"], secret)

    assert %{"alg" => "ES256", "kid" => "KEY1234567"} = JOSE.JWS.to_map(jws) |> elem(1)

    assert claims == %{
             "iss" => "TEAM123456",
             "sub" => "llc.abstractsyntax.qot",
             "aud" => "https://appleid.apple.com",
             "iat" => 1_800_000_000,
             "exp" => 1_800_000_000 + 300
           }
  end

  test "a key that isn't a PEM is an error, not a crash" do
    key = %{team_id: "T", key_id: "K", pem: "not a key"}
    assert {:error, :bad_key} = AppleTokens.signing_key(key)
  end

  test "Apple's token response gives the refresh token" do
    assert {:ok, "r1"} = AppleTokens.refresh_token(%{"refresh_token" => "r1", "id_token" => "x"})
    assert {:error, :no_refresh_token} = AppleTokens.refresh_token(%{"error" => "invalid_grant"})
    assert {:error, :no_refresh_token} = AppleTokens.refresh_token("nope")
  end
end
