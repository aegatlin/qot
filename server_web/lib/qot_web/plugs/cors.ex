defmodule QotWeb.Plugs.CORS do
  @moduledoc """
  CORS for the PWA's origin (`QotWeb.AppOrigin`), read at runtime so staging
  and production can differ. Bearer tokens, no cookies: no credentials.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    CORSPlug.call(
      conn,
      CORSPlug.init(origin: QotWeb.AppOrigin.origins(), credentials: false, max_age: 86_400)
    )
  end
end
