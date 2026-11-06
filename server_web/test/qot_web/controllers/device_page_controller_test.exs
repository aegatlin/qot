defmodule QotWeb.DevicePageControllerTest do
  # The server's old sign-in page: sign-in happens in the PWA now
  # (docs/records/2026-11-06-sign-in-through-the-pwa.md), and this path only
  # sends a link that still arrives here on to it.
  use QotWeb.ConnCase, async: true

  test "a sign-in link opens the PWA's sign-in page", %{conn: conn} do
    conn = get(conn, "/auth/device", %{token: "t0k"})
    assert redirected_to(conn, 302) == "https://app.example/auth/device?token=t0k"
  end

  test "the token is passed on escaped", %{conn: conn} do
    conn = get(conn, "/auth/device", %{token: "a b&c"})
    assert redirected_to(conn, 302) == "https://app.example/auth/device?token=a+b%26c"
  end

  test "without a token it opens the PWA's page, which says the link is bad", %{conn: conn} do
    conn = get(conn, "/auth/device")
    assert redirected_to(conn, 302) == "https://app.example/auth/device"
  end

  test "the server no longer takes codes itself", %{conn: conn} do
    conn = post(conn, "/auth/device", %{token: "t0k", user_code: "ABCD-EFGH"})
    assert conn.status == 404
  end
end
