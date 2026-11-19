defmodule QotWeb.BlobControllerTest do
  # The test config's limits: 1000 bytes a blob, 2500 an account.
  use QotWeb.ConnCase, async: true

  alias QotWeb.AuthHelpers

  @note "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c21"
  @blob "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c31"

  setup %{conn: conn} do
    auth = AuthHelpers.create_authenticated_user()
    %{conn: AuthHelpers.authenticate_conn(conn, auth.access_token), auth: auth}
  end

  defp upload(conn, id, bytes, note \\ @note) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> put("/api/blobs/#{id}?note_id=#{note}", bytes)
  end

  test "upload then download round-trips the bytes", %{conn: conn} do
    opaque = :crypto.strong_rand_bytes(700)
    assert conn |> upload(@blob, opaque) |> response(204)

    conn = get(conn, "/api/blobs/#{@blob}")
    assert response(conn, 200) == opaque
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "the server never guesses what a blob is from its upload", %{conn: conn} do
    conn
    |> put_req_header("content-type", "audio/mp4")
    |> put("/api/blobs/#{@blob}?note_id=#{@note}", "bytes")
    |> response(204)

    conn = conn |> put_req_header("accept", "audio/mp4") |> get("/api/blobs/#{@blob}")
    assert response(conn, 200) == "bytes"
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
  end

  test "a body that looks like a form or JSON is still just bytes", %{conn: conn} do
    # What curl and some HTTP clients send by default; the body parsers
    # must leave it alone.
    for {type, n} <- [{"application/x-www-form-urlencoded", 1}, {"application/json", 2}] do
      id = "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c5#{n}"
      bytes = "a=1&not json {" <> <<0, 255>>

      conn
      |> put_req_header("content-type", type)
      |> put("/api/blobs/#{id}?note_id=#{@note}", bytes)
      |> response(204)

      assert conn |> get("/api/blobs/#{id}") |> response(200) == bytes
    end
  end

  test "uploading again is fine and changes nothing", %{conn: conn} do
    assert conn |> upload(@blob, "first") |> response(204)
    assert conn |> upload(@blob, "second") |> response(204)
    assert conn |> get("/api/blobs/#{@blob}") |> response(200) == "first"
  end

  test "ids are case-insensitive UUIDs", %{conn: conn} do
    assert conn |> upload(String.upcase(@blob), "x") |> response(204)
    assert conn |> get("/api/blobs/#{@blob}") |> response(200) == "x"
    assert %{"error" => _} = conn |> upload("nope", "x") |> json_response(400)
    assert %{"error" => _} = conn |> upload(@blob, "x", "nope") |> json_response(400)
    assert %{"error" => _} = conn |> get("/api/blobs/nope") |> json_response(400)
  end

  test "a blob that isn't there is a 404", %{conn: conn} do
    assert %{"error" => _} = conn |> get("/api/blobs/#{@blob}") |> json_response(404)
  end

  test "another account's blob is a 404", %{conn: conn} do
    conn |> upload(@blob, "mine") |> response(204)
    other = AuthHelpers.create_authenticated_user("other@example.com")
    conn = AuthHelpers.authenticate_conn(build_conn(), other.access_token)
    assert conn |> get("/api/blobs/#{@blob}") |> json_response(404)
  end

  test "an empty upload is a 400", %{conn: conn} do
    assert %{"error" => _} = conn |> upload(@blob, "") |> json_response(400)
  end

  test "an upload over the size limit is a 413", %{conn: conn} do
    assert %{"error" => "too_large"} =
             conn |> upload(@blob, String.duplicate("x", 1001)) |> json_response(413)

    assert conn |> get("/api/blobs/#{@blob}") |> json_response(404)
  end

  test "an upload past the account's quota is a 403", %{conn: conn} do
    for n <- 1..2 do
      conn
      |> upload("0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c4#{n}", String.duplicate("x", 1000))
      |> response(204)
    end

    assert %{"error" => "quota_exceeded"} =
             conn |> upload(@blob, String.duplicate("x", 600)) |> json_response(403)
  end

  test "a push deletes blobs, and a later upload of one is a 410", %{conn: conn} do
    conn |> upload(@blob, "recording") |> response(204)

    body = %{
      changes: [%{note_id: @note, data: Base.encode64("tombstone")}],
      deleted_blobs: [@blob]
    }

    assert %{"cursor" => 1} = conn |> post("/api/sync/push", body) |> json_response(200)

    assert conn |> get("/api/blobs/#{@blob}") |> json_response(404)
    assert %{"error" => "deleted"} = conn |> upload(@blob, "recording") |> json_response(410)
  end

  test "a push with a malformed deleted_blobs is a 400 and appends nothing", %{conn: conn} do
    body = %{changes: [%{note_id: @note, data: Base.encode64("x")}], deleted_blobs: ["nope"]}
    assert %{"error" => _} = conn |> post("/api/sync/push", body) |> json_response(400)
    assert %{"changes" => []} = conn |> get("/api/sync/pull") |> json_response(200)
  end

  test "both endpoints require a token" do
    assert build_conn() |> upload(@blob, "x") |> json_response(401)
    assert build_conn() |> get("/api/blobs/#{@blob}") |> json_response(401)
  end

  test "the app may upload from the browser", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://app.example")
      |> put_req_header("access-control-request-method", "PUT")
      |> put_req_header("access-control-request-headers", "authorization,content-type")
      |> options("/api/blobs/#{@blob}")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example"]
    [methods] = get_resp_header(conn, "access-control-allow-methods")
    assert methods =~ "PUT"
  end
end
