defmodule Qot.AccountsTest do
  use Qot.DataCase, async: true

  alias Qot.Accounts

  describe "create_user/1" do
    test "creates a user with valid email" do
      assert {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
      assert user.email == "test@example.com"
      assert user.id != nil
    end

    test "fails with invalid email" do
      assert {:error, changeset} = Accounts.create_user(%{email: "invalid"})
      assert changeset.errors[:email] != nil
    end

    test "fails with duplicate email" do
      {:ok, _user} = Accounts.create_user(%{email: "test@example.com"})
      assert {:error, changeset} = Accounts.create_user(%{email: "test@example.com"})
      assert changeset.errors[:email] != nil
    end
  end

  describe "get_or_create_user/1" do
    test "creates new user if doesn't exist" do
      assert {:ok, user} = Accounts.get_or_create_user("new@example.com")
      assert user.email == "new@example.com"
    end

    test "returns existing user if already exists" do
      {:ok, user1} = Accounts.create_user(%{email: "existing@example.com"})
      {:ok, user2} = Accounts.get_or_create_user("existing@example.com")

      assert user1.id == user2.id
    end
  end

  describe "Token.generate_jwt/1" do
    test "generates valid JWT token" do
      {:ok, user} = Accounts.create_user(%{email: "test@example.com"})

      {:ok, token, _claims} = Accounts.Token.generate_jwt(user.id)
      assert is_binary(token)
    end
  end

  describe "Token.verify_jwt/1" do
    test "verifies valid JWT token" do
      {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
      {:ok, token, _claims} = Accounts.Token.generate_jwt(user.id)

      {:ok, claims} = Accounts.Token.verify_jwt(token)
      assert claims["user_id"] == user.id
    end

    test "rejects invalid JWT" do
      assert {:error, _} = Accounts.Token.verify_jwt("invalid.token.here")
    end
  end

  describe "device login" do
    import Swoosh.TestAssertions

    defp link_token_from_email do
      assert_email_sent(fn email ->
        [_, token] = Regex.run(~r{/auth/device\?token=([A-Za-z0-9_-]+)}, email.text_body)
        send(self(), {:link_token, token})
        true
      end)

      assert_received {:link_token, token}
      token
    end

    test "approving with the terminal's code lets the device collect tokens once" do
      {:ok, started} = Accounts.start_device_login("new@example.com")
      assert started.expires_in > 0 and started.interval > 0
      link_token = link_token_from_email()

      assert {:error, :authorization_pending} = Accounts.poll_device_login(started.device_code)
      assert {:ok, _} = Accounts.approve_device_login(link_token, started.user_code)

      assert {:ok, %{access_token: jwt, refresh_token: refresh, user: user}} =
               Accounts.poll_device_login(started.device_code)

      assert user.email == "new@example.com"
      assert {:ok, %{"user_id" => user_id}} = Accounts.Token.verify_jwt(jwt)
      assert user_id == user.id
      assert {:ok, _} = Accounts.refresh_access_token(refresh)

      assert {:error, :consumed} = Accounts.poll_device_login(started.device_code)
    end

    test "the email comes from the verified sending subdomain, and replies go to a person" do
      {:ok, _} = Accounts.start_device_login("someone@example.com")

      assert_email_sent(fn email ->
        assert email.from == {"Quantum of Thought", "noreply@mail.quantumofthought.com"}
        assert email.reply_to == {"Abstract Syntax", "contact@abstractsyntax.llc"}
        true
      end)
    end

    test "the email never contains the code from the terminal" do
      {:ok, started} = Accounts.start_device_login("someone@example.com")

      assert_email_sent(fn email ->
        refute email.text_body =~ started.user_code
        refute email.html_body =~ started.user_code
        true
      end)
    end

    test "a wrong code is counted and enough of them deny the login" do
      {:ok, started} = Accounts.start_device_login("a@example.com")
      link_token = link_token_from_email()

      for _ <- 1..Accounts.DeviceLogin.max_attempts() do
        assert {:error, :mismatch} = Accounts.approve_device_login(link_token, "ZZZZ-ZZZZ")
      end

      assert {:error, :denied} = Accounts.approve_device_login(link_token, started.user_code)
      assert {:error, :denied} = Accounts.poll_device_login(started.device_code)
    end

    test "unknown links and device codes are refused" do
      assert {:error, :not_found} = Accounts.approve_device_login("nope", "BCDF-GHJK")
      assert {:error, :not_found} = Accounts.poll_device_login("nope")
    end

    test "an invalid email is refused before anything is sent" do
      assert {:error, :invalid_email} = Accounts.start_device_login("not an email")
      assert_no_email_sent()
    end
  end
end
