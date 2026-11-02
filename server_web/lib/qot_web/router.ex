defmodule QotWeb.Router do
  use Phoenix.Router
  import Phoenix.Controller, only: [accepts: 2, put_secure_browser_headers: 2]

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # The sign-in page opened from the email. No session or CSRF token: the
  # form only works with the link token, which a forging site doesn't have.
  pipeline :page do
    plug(:accepts, ["html"])
    plug(:put_secure_browser_headers)
  end

  pipeline :authenticated do
    plug(QotWeb.Plugs.RequireAuth)
  end

  scope "/", QotWeb do
    get("/health", HealthController, :show)
  end

  scope "/api", QotWeb do
    pipe_through(:api)

    post("/auth/device", AuthController, :start_device_login)
    post("/auth/device/token", AuthController, :poll_device_login)
    post("/auth/refresh", AuthController, :refresh)
    post("/auth/logout", AuthController, :logout)
  end

  scope "/auth", QotWeb do
    pipe_through(:page)

    get("/device", DevicePageController, :show)
    post("/device", DevicePageController, :approve)
  end

  scope "/api", QotWeb do
    pipe_through([:api, :authenticated])

    post("/sync/push", SyncController, :push)
    get("/sync/pull", SyncController, :pull)
  end
end
