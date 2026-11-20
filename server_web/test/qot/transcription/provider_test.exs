defmodule Qot.Transcription.ProviderTest do
  use ExUnit.Case, async: true

  alias Qot.Transcription.Provider

  defp config(plug) do
    %{
      url: "https://stt.example/v1/audio/transcriptions",
      key: "secret-key",
      model: "a-model",
      req_options: [plug: plug]
    }
  end

  test "the recording goes up as a multipart file with the model and the key" do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.method, conn.request_path, conn.req_headers, body})
      Req.Test.json(conn, %{"text" => "call the plumber"})
    end

    assert Provider.transcribe("AUDIOBYTES", "memo.m4a", config(plug)) ==
             {:ok, "call the plumber"}

    assert_received {:request, "POST", "/v1/audio/transcriptions", headers, body}
    assert {"authorization", "Bearer secret-key"} in headers
    assert {_, "multipart/form-data" <> _} = List.keyfind(headers, "content-type", 0)
    assert body =~ ~s(name="model")
    assert body =~ "a-model"
    assert body =~ ~s(name="file"; filename="memo.m4a")
    assert body =~ "AUDIOBYTES"
  end

  test "a refusal is an error, not text" do
    plug = fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => %{"message" => "bad key"}})
    end

    assert Provider.transcribe("a", "memo.m4a", config(plug)) == {:error, {:status, 401}}
  end

  test "an answer without text is an error" do
    plug = fn conn -> Req.Test.json(conn, %{"words" => []}) end
    assert Provider.transcribe("a", "memo.m4a", config(plug)) == {:error, {:status, 200}}
  end
end
