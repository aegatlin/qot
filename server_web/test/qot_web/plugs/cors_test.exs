defmodule QotWeb.CORSTest do
  # The test config's :app_url is https://app.example.
  use QotWeb.ConnCase, async: true

  test "the app's origin gets CORS headers, without credentials", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://app.example")
      |> get("/health")

    assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example"]
    assert get_resp_header(conn, "access-control-allow-credentials") == []
  end

  test "a preflight from the app allows Authorization", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://app.example")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "authorization,content-type")
      |> options("/api/sync/push")

    assert conn.status == 204
    [allowed] = get_resp_header(conn, "access-control-allow-headers")
    assert allowed =~ ~r/authorization/i
  end

  test "another origin gets no CORS headers", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://evil.example")
      |> get("/health")

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
