defmodule QotWeb.DeviceApproveTest do
  @moduledoc """
  The PWA's sign-in page: it reads the link, then approves with the code. A
  correct code approves the device that asked and, unless told not to, signs
  in the browser too (docs/records/2026-11-06-sign-in-through-the-pwa.md).
  """
  use QotWeb.ConnCase, async: true

  import Swoosh.TestAssertions

  alias Qot.Accounts

  setup do
    {:ok, started} = Accounts.start_device_login("web@example.com")

    assert_email_sent(fn email ->
      [_, url, token] =
        Regex.run(~r{(https?://[^\s"]+/auth/device)\?token=([A-Za-z0-9_-]+)}, email.text_body)

      send(self(), {:link, url, token})
      true
    end)

    assert_received {:link, url, link_token}
    %{started: started, link_token: link_token, url: url}
  end

  test "the emailed link goes to the PWA", %{url: url} do
    assert url == "https://app.example/auth/device"
  end

  describe "GET /api/auth/device/link" do
    test "says which account a live link signs in to", %{conn: conn, link_token: t} do
      assert %{"email" => "web@example.com"} =
               conn |> get("/api/auth/device/link", %{token: t}) |> json_response(200)
    end

    test "reading the link approves nothing", %{conn: conn, link_token: t, started: s} do
      get(conn, "/api/auth/device/link", %{token: t})
      assert {:error, :authorization_pending} = Accounts.poll_device_login(s.device_code)
    end

    test "an unknown link is expired", %{conn: conn} do
      assert %{"error" => "expired"} =
               conn |> get("/api/auth/device/link", %{token: "nope"}) |> json_response(404)
    end
  end

  describe "POST /api/auth/device/approve" do
    test "the right code approves the device and signs in the browser",
         %{conn: conn, link_token: t, started: s} do
      body =
        conn
        |> post("/api/auth/device/approve", %{token: t, user_code: s.user_code})
        |> json_response(200)

      assert %{
               "access_token" => access,
               "refresh_token" => refresh,
               "user" => %{"email" => "web@example.com"}
             } = body

      assert {:ok, %{"user_id" => _}} = Accounts.Token.verify_jwt(access)
      assert {:ok, _} = Accounts.refresh_access_token(refresh)

      # The device that asked gets its own, different tokens.
      assert {:ok, device} = Accounts.poll_device_login(s.device_code)
      assert device.refresh_token != refresh
      assert device.user.id == body["user"]["id"]
    end

    test "the code is accepted however it is typed", %{conn: conn, link_token: t, started: s} do
      typed = s.user_code |> String.downcase() |> String.replace("-", " ")

      assert %{"access_token" => _} =
               conn
               |> post("/api/auth/device/approve", %{token: t, user_code: typed})
               |> json_response(200)
    end

    test "sign_in_browser: false approves the device only",
         %{conn: conn, link_token: t, started: s} do
      body =
        conn
        |> post("/api/auth/device/approve", %{
          token: t,
          user_code: s.user_code,
          sign_in_browser: false
        })
        |> json_response(200)

      assert body == %{"approved" => true}
      assert {:ok, _} = Accounts.poll_device_login(s.device_code)
    end

    test "a wrong code returns no tokens and counts", %{conn: conn, link_token: t, started: s} do
      assert %{"error" => "mismatch"} =
               conn
               |> post("/api/auth/device/approve", %{token: t, user_code: "ZZZZ-ZZZZ"})
               |> json_response(422)

      assert {:error, :authorization_pending} = Accounts.poll_device_login(s.device_code)

      for _ <- 2..5,
          do: post(conn, "/api/auth/device/approve", %{token: t, user_code: "ZZZZ-ZZZZ"})

      assert %{"error" => "denied"} =
               conn
               |> post("/api/auth/device/approve", %{token: t, user_code: s.user_code})
               |> json_response(410)
    end

    test "a link approves once", %{conn: conn, link_token: t, started: s} do
      post(conn, "/api/auth/device/approve", %{token: t, user_code: s.user_code})

      assert %{"error" => "approved"} =
               conn
               |> post("/api/auth/device/approve", %{token: t, user_code: s.user_code})
               |> json_response(410)
    end

    test "an unknown link or missing fields", %{conn: conn} do
      assert %{"error" => "expired"} =
               conn
               |> post("/api/auth/device/approve", %{token: "nope", user_code: "BBBB-BBBB"})
               |> json_response(404)

      assert %{"error" => _} =
               conn |> post("/api/auth/device/approve", %{}) |> json_response(400)
    end
  end

  test "the old server page sends the link on to the PWA", %{conn: conn, link_token: t} do
    conn = get(conn, "/auth/device", %{token: t})
    assert redirected_to(conn, 302) == "https://app.example/auth/device?token=#{t}"
  end
end
