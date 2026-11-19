defmodule QotWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :qot

  # WebSocket configuration
  socket("/socket", QotWeb.UserSocket,
    # Browsers may connect only from the PWA (native clients send no Origin).
    websocket: [check_origin: {QotWeb.AppOrigin, :allowed?, []}],
    longpoll: false
  )

  plug(QotWeb.Plugs.CORS)

  plug(:parse_body)

  plug(QotWeb.Router)

  @parsers Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)

  # A blob's body is the blob, whatever `content-type` it arrives with, and
  # is read by QotWeb.BlobController under its own size limit. Parsing it
  # here would consume it, or reject it as a form that is too large.
  defp parse_body(%Plug.Conn{path_info: ["api", "blobs" | _]} = conn, _opts) do
    conn |> Plug.Conn.fetch_query_params() |> Map.put(:body_params, %{})
  end

  defp parse_body(conn, _opts), do: Plug.Parsers.call(conn, @parsers)
end
