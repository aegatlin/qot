defmodule QotWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :qot

  # WebSocket configuration
  socket("/socket", QotWeb.UserSocket,
    # Browsers may connect only from the PWA (native clients send no Origin).
    websocket: [check_origin: {QotWeb.AppOrigin, :allowed?, []}],
    longpoll: false
  )

  plug(QotWeb.Plugs.CORS)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(QotWeb.Router)
end
