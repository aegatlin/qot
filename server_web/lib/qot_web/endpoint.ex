defmodule QotWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :qot

  # WebSocket configuration
  socket("/socket", QotWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  plug(CORSPlug, origin: Application.compile_env(:qot, :cors_origins, []))

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(QotWeb.Router)
end
