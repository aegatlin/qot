defmodule QotWeb.HealthController do
  use QotWeb, :controller

  require Logger

  # For the platform's health checks: no auth, no content negotiation.
  # `commit` is the deployed git commit, so a smoke test after a deploy can
  # tell the new release is the one answering.
  def show(conn, _params) do
    case Qot.Health.check() do
      :ok ->
        json(conn, %{status: "ok", commit: Application.get_env(:qot, :commit)})

      {:error, reason} ->
        Logger.error("health check failed: #{reason}")
        conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
