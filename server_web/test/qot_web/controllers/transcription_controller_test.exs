defmodule QotWeb.TranscriptionControllerTest do
  # The test config: Qot.TestTranscriber, 60 seconds a month, and the blob
  # limit of 1000 bytes a body.
  use QotWeb.ConnCase, async: true

  alias Qot.Accounts
  alias Qot.Transcription
  alias QotWeb.AuthHelpers

  setup %{conn: conn} do
    auth = AuthHelpers.create_authenticated_user()
    %{conn: AuthHelpers.authenticate_conn(conn, auth.access_token), auth: auth}
  end

  defp plus(%{auth: auth}) do
    {:ok, _} = Accounts.set_plan(auth.email, "plus")
    :ok
  end

  defp send_audio(conn, bytes, query \\ "") do
    conn
    |> put_req_header("content-type", "audio/mp4")
    |> post("/api/transcriptions#{query}", bytes)
  end

  test "it needs a sign-in" do
    conn = build_conn() |> send_audio("audio")
    assert json_response(conn, 401)
  end

  test "an account on the free plan is refused, and nothing is sent on", %{conn: conn} do
    conn = send_audio(conn, "audio")
    assert json_response(conn, 402) == %{"error" => "plan_required"}
    refute_received {:transcribed, _, _}
  end

  describe "on the plus plan" do
    setup :plus

    test "the recording's text comes back, trimmed", %{conn: conn} do
      conn = send_audio(conn, "audio", "?duration_ms=4200")
      assert json_response(conn, 200) == %{"text" => "heard audio"}
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert_received {:transcribed, "audio", "memo.m4a"}
    end

    test "the provider is told the format by the file's name", %{conn: conn} do
      conn
      |> put_req_header("content-type", "audio/webm; codecs=opus")
      |> post("/api/transcriptions", "audio")
      |> json_response(200)

      assert_received {:transcribed, "audio", "memo.webm"}
    end

    test "the seconds are counted, and nothing else is kept", %{conn: conn, auth: auth} do
      send_audio(conn, "audio", "?duration_ms=4200") |> json_response(200)
      send_audio(conn, "audio", "?duration_ms=10000") |> json_response(200)
      assert Transcription.used_seconds(auth.user_id) == 15
    end

    test "past the month's allowance it is refused", %{conn: conn, auth: auth} do
      send_audio(conn, "audio", "?duration_ms=50000") |> json_response(200)
      conn = send_audio(conn, "audio", "?duration_ms=11000")
      assert json_response(conn, 429) == %{"error" => "allowance_used"}
      assert Transcription.used_seconds(auth.user_id) == 50
    end

    test "a provider failure costs the account nothing", %{conn: conn, auth: auth} do
      conn = send_audio(conn, "static", "?duration_ms=5000")
      assert json_response(conn, 502) == %{"error" => "provider_failed"}
      assert Transcription.used_seconds(auth.user_id) == 0
    end

    test "an empty body is refused", %{conn: conn} do
      assert conn |> send_audio("") |> json_response(400)
    end

    test "a body over the size limit is refused", %{conn: conn} do
      conn = send_audio(conn, String.duplicate("a", 1001))
      assert json_response(conn, 413) == %{"error" => "too_large"}
    end
  end
end
