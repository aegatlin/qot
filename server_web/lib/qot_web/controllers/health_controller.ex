defmodule QotWeb.HealthController do
  use QotWeb, :controller

  require Logger

  # For the platform's health checks: no auth, no content negotiation.
  def show(conn, _params) do
    case Qot.Health.check() do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, reason} ->
        Logger.error("health check failed: #{reason}")
        conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
