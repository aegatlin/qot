defmodule QotWeb.SyncControllerTest do
  use QotWeb.ConnCase, async: true

  alias QotWeb.AuthHelpers

  @note_id "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c21"

  setup %{conn: conn} do
    auth = AuthHelpers.create_authenticated_user()
    %{conn: AuthHelpers.authenticate_conn(conn, auth.access_token), auth: auth}
  end

  defp push_body(data), do: %{changes: [%{note_id: @note_id, data: Base.encode64(data)}]}

  test "push then pull round-trips the bytes", %{conn: conn} do
    assert %{"cursor" => 1} =
             conn |> post("/api/sync/push", push_body("hello")) |> json_response(200)

    assert %{"changes" => [change], "cursor" => 1, "more" => false} =
             conn |> get("/api/sync/pull", %{since: 0}) |> json_response(200)

    assert change == %{"seq" => 1, "note_id" => @note_id, "data" => Base.encode64("hello")}
  end

  test "pull with no since starts from the beginning", %{conn: conn} do
    post(conn, "/api/sync/push", push_body("x"))
    assert %{"changes" => [_]} = conn |> get("/api/sync/pull") |> json_response(200)
  end

  test "a malformed push is a 400 with a reason", %{conn: conn} do
    body = %{changes: [%{note_id: "nope", data: "aGk="}]}
    assert %{"error" => _} = conn |> post("/api/sync/push", body) |> json_response(400)
  end

  test "a malformed cursor is a 400", %{conn: conn} do
    assert %{"error" => _} = conn |> get("/api/sync/pull", %{since: "x"}) |> json_response(400)
  end

  test "both endpoints require a token" do
    conn = build_conn()
    assert conn |> post("/api/sync/push", push_body("x")) |> json_response(401)
    assert build_conn() |> get("/api/sync/pull") |> json_response(401)
  end
end
