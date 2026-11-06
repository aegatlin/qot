defmodule QotWeb.DevicePageControllerTest do
  # The server's own page, as served when there is no PWA (no :app_url).
  # Changes app config, so not async.
  use QotWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias Qot.Accounts

  setup do
    app_url = Application.get_env(:qot, :app_url)
    Application.put_env(:qot, :app_url, nil)
    on_exit(fn -> Application.put_env(:qot, :app_url, app_url) end)

    {:ok, started} = Accounts.start_device_login("page@example.com")

    assert_email_sent(fn email ->
      [_, token] = Regex.run(~r{/auth/device\?token=([A-Za-z0-9_-]+)}, email.text_body)
      send(self(), {:link_token, token})
      true
    end)

    assert_received {:link_token, link_token}
    %{started: started, link_token: link_token}
  end

  test "the link opens a form asking for the terminal's code", %{conn: conn, link_token: t} do
    html = conn |> get("/auth/device", %{token: t}) |> html_response(200)
    assert html =~ "code shown in your terminal"
    assert html =~ ~s(name="user_code")
  end

  test "opening the link does not approve the login", %{conn: conn, link_token: t, started: s} do
    get(conn, "/auth/device", %{token: t})
    assert {:error, :authorization_pending} = Accounts.poll_device_login(s.device_code)
  end

  test "the right code signs the terminal in", %{conn: conn, link_token: t, started: s} do
    html =
      conn
      |> post("/auth/device", %{token: t, user_code: s.user_code})
      |> html_response(200)

    assert html =~ "return to your terminal"
    assert {:ok, _} = Accounts.poll_device_login(s.device_code)
  end

  test "a wrong code shows the form again with an error", %{conn: conn, link_token: t} do
    html =
      conn
      |> post("/auth/device", %{token: t, user_code: "ZZZZ-ZZZZ"})
      |> html_response(422)

    assert html =~ "match"
    assert html =~ ~s(name="user_code")
  end

  test "an unknown link says so", %{conn: conn} do
    assert conn |> get("/auth/device", %{token: "nope"}) |> html_response(404) =~ "expired"
  end
end
