defmodule QotWeb.HealthControllerTest do
  use QotWeb.ConnCase, async: true

  test "GET /health is 200 when the database is reachable", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/health") |> json_response(200)
  end

  test "GET /health needs no token and no Accept header" do
    conn = build_conn() |> delete_req_header("accept") |> get("/health")
    assert conn.status == 200
  end
end
