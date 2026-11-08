defmodule QotWeb.Router do
  use Phoenix.Router
  import Phoenix.Controller, only: [accepts: 2, put_secure_browser_headers: 2]

  pipeline :api do
    plug(:accepts, ["json"])
    plug(QotWeb.Plugs.ClientIP)
  end

  # Old sign-in links, sent on to the PWA (DevicePageController).
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
    get("/auth/device/link", AuthController, :device_link)
    post("/auth/device/approve", AuthController, :approve_device_login)
    post("/auth/apple", AuthController, :sign_in_with_apple)
    post("/auth/refresh", AuthController, :refresh)
    post("/auth/logout", AuthController, :logout)
  end

  scope "/auth", QotWeb do
    pipe_through(:page)

    get("/device", DevicePageController, :show)
  end

  scope "/api", QotWeb do
    pipe_through([:api, :authenticated])

    post("/sync/push", SyncController, :push)
    get("/sync/pull", SyncController, :pull)
    delete("/account", AccountController, :delete)
  end
end
