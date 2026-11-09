defmodule QotWeb.AppleSignInTest do
  use QotWeb.ConnCase, async: true

  alias Qot.Accounts
  alias Qot.Accounts.User
  alias Qot.AppleTestKeys, as: Keys
  alias Qot.Repo

  @nonce "raw-nonce-from-the-app"

  defp sign_in(conn, claims, opts \\ []) do
    params = %{identity_token: Keys.sign(claims, opts), nonce: Keyword.get(opts, :nonce, @nonce)}

    params =
      case Keyword.fetch(opts, :code) do
        {:ok, code} -> Map.put(params, :authorization_code, code)
        :error -> params
      end

    post(conn, "/api/auth/apple", params)
  end

  test "creates an account and returns the device sign-in's tokens", %{conn: conn} do
    body = conn |> sign_in(Keys.claims(@nonce)) |> json_response(200)

    assert %{
             "access_token" => access_token,
             "refresh_token" => refresh_token,
             "user" => %{"id" => id, "email" => "person@example.com"}
           } = body

    assert {:ok, %{"user_id" => ^id}} = Accounts.Token.verify_jwt(access_token)
    assert {:ok, _} = Accounts.refresh_access_token(refresh_token)
    assert Repo.get!(User, id).apple_sub == "001234.abcdef.0123"
  end

  test "signs in to the account already linked, whatever the token's email", %{conn: conn} do
    %{"user" => %{"id" => id}} = conn |> sign_in(Keys.claims(@nonce)) |> json_response(200)

    claims = Keys.claims(@nonce) |> Map.drop(["email", "email_verified"])
    assert %{"user" => %{"id" => ^id}} = conn |> sign_in(claims) |> json_response(200)

    claims = Keys.claims(@nonce, %{"email" => "changed@example.com"})
    assert %{"user" => %{"id" => ^id}} = conn |> sign_in(claims) |> json_response(200)
  end

  test "links the account with the same verified email, ignoring case", %{conn: conn} do
    {:ok, user} = Accounts.create_user(%{email: "Person@Example.com"})
    claims = Keys.claims(@nonce, %{"email_verified" => "true"})

    assert %{"user" => %{"id" => id, "email" => "Person@Example.com"}} =
             conn |> sign_in(claims) |> json_response(200)

    assert id == user.id
    assert Repo.get!(User, id).apple_sub == "001234.abcdef.0123"
  end

  test "won't link an unverified email to an existing account", %{conn: conn} do
    {:ok, _} = Accounts.create_user(%{email: "person@example.com"})
    claims = Keys.claims(@nonce, %{"email_verified" => false})

    assert %{"error" => "email_in_use"} = conn |> sign_in(claims) |> json_response(409)
  end

  test "needs an email to create an account", %{conn: conn} do
    claims = Keys.claims(@nonce) |> Map.drop(["email", "email_verified"])
    assert %{"error" => "email_required"} = conn |> sign_in(claims) |> json_response(422)
  end

  test "a deleted account's Apple link goes with it", %{conn: conn} do
    %{"user" => %{"id" => id}} = conn |> sign_in(Keys.claims(@nonce)) |> json_response(200)
    :ok = Accounts.delete_user(id)

    assert %{"user" => %{"id" => new_id}} =
             conn |> sign_in(Keys.claims(@nonce)) |> json_response(200)

    assert new_id != id
  end

  describe "the authorization code (#88: kept so deleting the account can revoke it)" do
    test "is exchanged for Apple's refresh token, stored with its client id", %{conn: conn} do
      %{"user" => %{"id" => id}} =
        conn |> sign_in(Keys.claims(@nonce), code: "c1") |> json_response(200)

      assert_received {:apple_exchange, "llc.abstractsyntax.qot", "c1"}
      user = Repo.get!(User, id)
      assert user.apple_refresh_token == "apple-refresh-c1"
      assert user.apple_client_id == "llc.abstractsyntax.qot"
    end

    test "a later sign-in's code replaces the stored token", %{conn: conn} do
      %{"user" => %{"id" => id}} =
        conn |> sign_in(Keys.claims(@nonce), code: "c1") |> json_response(200)

      conn |> sign_in(Keys.claims(@nonce), code: "c2") |> json_response(200)
      assert Repo.get!(User, id).apple_refresh_token == "apple-refresh-c2"
    end

    test "an exchange Apple refuses doesn't stop the sign-in", %{conn: conn} do
      Process.put(:apple_exchange_result, {:error, :invalid_grant})

      %{"user" => %{"id" => id}} =
        conn |> sign_in(Keys.claims(@nonce), code: "c1") |> json_response(200)

      assert Repo.get!(User, id).apple_refresh_token == nil
    end

    test "without one (older apps), nothing is exchanged", %{conn: conn} do
      conn |> sign_in(Keys.claims(@nonce)) |> json_response(200)
      refute_received {:apple_exchange, _, _}
    end

    test "a token that fails its checks exchanges nothing", %{conn: conn} do
      conn |> sign_in(Keys.claims("another nonce"), code: "c1") |> json_response(401)
      refute_received {:apple_exchange, _, _}
    end
  end

  describe "refuses an invalid identity token with a 401" do
    test "signed by another key", %{conn: conn} do
      assert %{"error" => "invalid_token"} =
               conn |> sign_in(Keys.claims(@nonce), jwk: Keys.other_jwk()) |> json_response(401)
    end

    test "under a key Apple never published", %{conn: conn} do
      assert %{"error" => "invalid_token"} =
               conn |> sign_in(Keys.claims(@nonce), kid: "unknown") |> json_response(401)
    end

    test "for another app, from another issuer, or expired", %{conn: conn} do
      for overrides <- [
            %{"aud" => "com.example.other"},
            %{"iss" => "https://evil.example"},
            %{"exp" => System.os_time(:second) - 10}
          ] do
        assert %{"error" => "invalid_token"} =
                 conn |> sign_in(Keys.claims(@nonce, overrides)) |> json_response(401)
      end
    end

    test "with another nonce", %{conn: conn} do
      assert %{"error" => "invalid_token"} =
               conn |> sign_in(Keys.claims(@nonce), nonce: "other") |> json_response(401)
    end

    test "that isn't a JWT", %{conn: conn} do
      assert %{"error" => "invalid_token"} =
               conn
               |> post("/api/auth/apple", %{identity_token: "nope", nonce: @nonce})
               |> json_response(401)
    end
  end

  test "needs both the identity token and the nonce", %{conn: conn} do
    token = Keys.sign(Keys.claims(@nonce))

    for params <- [%{}, %{identity_token: token}, %{nonce: @nonce}] do
      assert %{"error" => "identity_token and nonce are required"} =
               conn |> post("/api/auth/apple", params) |> json_response(400)
    end
  end
end
