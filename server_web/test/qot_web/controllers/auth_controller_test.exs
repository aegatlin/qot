defmodule QotWeb.AuthControllerTest do
  use QotWeb.ConnCase, async: true

  describe "POST /api/auth/device" do
    test "starts a device login", %{conn: conn} do
      body = conn |> post("/api/auth/device", %{email: "cli@example.com"}) |> json_response(200)

      assert %{"device_code" => _, "user_code" => code, "expires_in" => _, "interval" => _} =
               body

      assert code =~ ~r/^[A-Z]{4}-[A-Z]{4}$/
    end

    test "says where the web app is, so the device can point to it", %{conn: conn} do
      assert %{"app_url" => "https://app.example"} =
               conn |> post("/api/auth/device", %{email: "cli@example.com"}) |> json_response(200)
    end

    test "rejects a missing or invalid email", %{conn: conn} do
      assert %{"error" => _} = conn |> post("/api/auth/device", %{}) |> json_response(400)

      assert %{"error" => _} =
               conn |> post("/api/auth/device", %{email: "nope"}) |> json_response(400)
    end
  end

  describe "POST /api/auth/device/token" do
    test "is pending until approved", %{conn: conn} do
      %{"device_code" => device_code} =
        conn |> post("/api/auth/device", %{email: "cli@example.com"}) |> json_response(200)

      assert %{"error" => "authorization_pending"} =
               conn
               |> post("/api/auth/device/token", %{device_code: device_code})
               |> json_response(400)
    end

    test "refuses an unknown device code", %{conn: conn} do
      assert %{"error" => "invalid_device_code"} =
               conn |> post("/api/auth/device/token", %{device_code: "x"}) |> json_response(400)
    end
  end

  describe "POST /api/auth/refresh" do
    test "returns error with invalid refresh token", %{conn: conn} do
      conn = post(conn, "/api/auth/refresh", %{refresh_token: "invalid"})

      assert json_response(conn, 401) == %{"error" => "Invalid or expired refresh token"}
    end

    test "returns error without refresh token", %{conn: conn} do
      conn = post(conn, "/api/auth/refresh", %{})

      assert json_response(conn, 400) == %{"error" => "Refresh token is required"}
    end
  end

  describe "POST /api/auth/logout" do
    test "returns success message", %{conn: conn} do
      # Logout returns success even with invalid tokens (idempotent)
      conn = post(conn, "/api/auth/logout", %{refresh_token: "any_token"})

      assert json_response(conn, 200) == %{"message" => "Logged out successfully"}
    end

    test "returns error without refresh token", %{conn: conn} do
      conn = post(conn, "/api/auth/logout", %{})

      assert json_response(conn, 400) == %{"error" => "Refresh token is required"}
    end
  end
end
