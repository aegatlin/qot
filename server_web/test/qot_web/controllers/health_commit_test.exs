defmodule QotWeb.HealthCommitTest do
  # Changes app config, so not async.
  use QotWeb.ConnCase, async: false

  setup do
    commit = Application.get_env(:qot, :commit)
    on_exit(fn -> Application.put_env(:qot, :commit, commit) end)
  end

  test "GET /health names the deployed commit, so a smoke test knows it's live", %{conn: conn} do
    Application.put_env(:qot, :commit, "abc123")

    assert %{"status" => "ok", "commit" => "abc123"} =
             conn |> get("/health") |> json_response(200)
  end

  test "GET /health without a known commit says null", %{conn: conn} do
    Application.put_env(:qot, :commit, nil)
    assert %{"status" => "ok", "commit" => nil} = conn |> get("/health") |> json_response(200)
  end
end
