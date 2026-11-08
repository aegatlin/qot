defmodule Qot.Accounts.AppleIdentityTest do
  use ExUnit.Case, async: true

  alias Qot.Accounts.AppleIdentity
  alias Qot.AppleTestKeys, as: Keys

  @nonce "raw-nonce-from-the-app"
  @client_ids ["llc.abstractsyntax.qot"]

  defp now, do: System.os_time(:second)

  defp verify(token, nonce \\ @nonce, client_ids \\ @client_ids) do
    AppleIdentity.verify(token, Keys.private_jwk(), nonce, client_ids, now())
  end

  describe "kid/1" do
    test "reads the key id from the token's header" do
      assert {:ok, "test-kid"} = Keys.claims(@nonce) |> Keys.sign() |> AppleIdentity.kid()
    end

    test "refuses something that isn't a JWT" do
      assert {:error, :malformed} = AppleIdentity.kid("not a token")
      assert {:error, :malformed} = AppleIdentity.kid("a.b.c")
    end

    test "refuses a header without a kid" do
      header = Base.url_encode64(~s({"alg":"RS256"}), padding: false)
      assert {:error, :malformed} = AppleIdentity.kid(header <> ".e30.sig")
    end
  end

  describe "verify/5" do
    test "accepts Apple's token and returns who it is" do
      token = Keys.claims(@nonce) |> Keys.sign()

      assert {:ok,
              %{sub: "001234.abcdef.0123", email: "person@example.com", email_verified: true}} =
               verify(token)
    end

    test "reads email_verified sent as the string \"true\"" do
      token = Keys.claims(@nonce, %{"email_verified" => "true"}) |> Keys.sign()
      assert {:ok, %{email_verified: true}} = verify(token)

      token = Keys.claims(@nonce, %{"email_verified" => "false"}) |> Keys.sign()
      assert {:ok, %{email_verified: false}} = verify(token)
    end

    test "a token without an email has none" do
      token = Keys.claims(@nonce) |> Map.drop(["email", "email_verified"]) |> Keys.sign()
      assert {:ok, %{email: nil, email_verified: false}} = verify(token)
    end

    test "refuses a signature by another key" do
      token = Keys.claims(@nonce) |> Keys.sign(jwk: Keys.other_jwk())
      assert {:error, :bad_signature} = verify(token)
    end

    test "refuses an algorithm other than RS256" do
      token = Keys.claims(@nonce) |> Keys.sign(alg: "RS512")
      assert {:error, :bad_signature} = verify(token)
    end

    test "refuses a token for another app" do
      token = Keys.claims(@nonce, %{"aud" => "com.example.other"}) |> Keys.sign()
      assert {:error, :bad_audience} = verify(token)
    end

    test "accepts any of the allowed client ids" do
      token = Keys.claims(@nonce, %{"aud" => "llc.abstractsyntax.qot.web"}) |> Keys.sign()

      assert {:ok, _} =
               verify(token, @nonce, ["llc.abstractsyntax.qot", "llc.abstractsyntax.qot.web"])
    end

    test "refuses another issuer" do
      token = Keys.claims(@nonce, %{"iss" => "https://evil.example"}) |> Keys.sign()
      assert {:error, :bad_issuer} = verify(token)
    end

    test "refuses an expired token" do
      token = Keys.claims(@nonce, %{"exp" => now() - 1}) |> Keys.sign()
      assert {:error, :expired} = verify(token)

      token = Keys.claims(@nonce) |> Map.delete("exp") |> Keys.sign()
      assert {:error, :expired} = verify(token)
    end

    test "refuses a token whose nonce isn't the hash of the one given" do
      token = Keys.claims(@nonce) |> Keys.sign()
      assert {:error, :bad_nonce} = verify(token, "another nonce")

      # The raw nonce in the token instead of its hash.
      token = Keys.claims(@nonce, %{"nonce" => @nonce}) |> Keys.sign()
      assert {:error, :bad_nonce} = verify(token)

      token = Keys.claims(@nonce) |> Map.delete("nonce") |> Keys.sign()
      assert {:error, :bad_nonce} = verify(token)
    end

    test "refuses a token without a subject" do
      token = Keys.claims(@nonce) |> Map.delete("sub") |> Keys.sign()
      assert {:error, :bad_subject} = verify(token)

      token = Keys.claims(@nonce, %{"sub" => ""}) |> Keys.sign()
      assert {:error, :bad_subject} = verify(token)
    end

    test "refuses garbage" do
      assert {:error, :malformed} = verify("garbage")
    end
  end

  describe "account/3" do
    @identity %{sub: "s1", email: "Person@Example.com", email_verified: true}

    test "the user already linked to the Apple account" do
      user = %{id: 1, apple_sub: "s1"}
      other = %{id: 2, apple_sub: nil}
      assert {:existing, ^user} = AppleIdentity.account(@identity, user, other)
    end

    test "links the account with the same verified email" do
      user = %{id: 2, apple_sub: nil}
      assert {:link, ^user} = AppleIdentity.account(@identity, nil, user)
    end

    test "creates an account when nobody has the email" do
      assert {:create, %{email: "Person@Example.com", apple_sub: "s1"}} =
               AppleIdentity.account(@identity, nil, nil)
    end

    test "never links an unverified email" do
      identity = %{@identity | email_verified: false}

      assert {:error, :email_in_use} =
               AppleIdentity.account(identity, nil, %{id: 2, apple_sub: nil})

      assert {:create, _} = AppleIdentity.account(identity, nil, nil)
    end

    test "never moves an account to a second Apple account" do
      assert {:error, :email_in_use} =
               AppleIdentity.account(@identity, nil, %{id: 2, apple_sub: "s0"})
    end

    test "without an email, only an existing link signs in" do
      identity = %{sub: "s1", email: nil, email_verified: false}
      assert {:error, :no_email} = AppleIdentity.account(identity, nil, nil)
      user = %{id: 1, apple_sub: "s1"}
      assert {:existing, ^user} = AppleIdentity.account(identity, user, nil)
    end
  end
end
