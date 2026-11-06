defmodule QotWeb.DevicePageController do
  @moduledoc """
  Where emailed sign-in links pointed before the PWA: sign-in happens on the
  PWA's `/auth/device` page now (docs/records/2026-11-06-sign-in-through-the-pwa.md),
  and this sends any link that still arrives here on to it. It costs nothing
  to keep, so old links never break.
  """

  use Phoenix.Controller, formats: [:html]

  def show(conn, %{"token" => token}) when is_binary(token) do
    redirect(conn, external: QotWeb.AppOrigin.sign_in_url(token))
  end

  def show(conn, _params) do
    redirect(conn, external: String.trim_trailing(QotWeb.AppOrigin.url(), "/") <> "/auth/device")
  end
end
