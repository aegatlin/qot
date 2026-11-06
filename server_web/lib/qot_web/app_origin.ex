defmodule QotWeb.AppOrigin do
  @moduledoc """
  Where the PWA lives (`:app_url`, from `APP_URL`, required in production),
  and what that means for the API: its origin is the one browser origin
  allowed to call the API (CORS) and open the socket, and emailed sign-in
  links open its sign-in page
  (docs/records/2026-11-06-sign-in-through-the-pwa.md). Native clients send
  no `Origin` and are unaffected.
  """

  @doc "The PWA's base URL."
  def url, do: Application.fetch_env!(:qot, :app_url)

  @doc "The browser origins allowed to call the API."
  def origins, do: [origin(url())]

  @doc ~S|"scheme://host[:port]" of a URL, the port only when not the default.|
  def origin(url) when is_binary(url) do
    uri = URI.parse(url)
    default = URI.default_port(uri.scheme)
    port = if uri.port && uri.port != default, do: ":#{uri.port}", else: ""
    "#{uri.scheme}://#{uri.host}#{port}"
  end

  @doc "The socket's `check_origin`: `{QotWeb.AppOrigin, :allowed?, []}`."
  def allowed?(%URI{} = uri), do: allowed?(uri, origins())

  def allowed?(%URI{} = uri, allowed), do: origin(URI.to_string(uri)) in allowed

  @doc "The link a sign-in email carries."
  def sign_in_url(link_token), do: sign_in_url(url(), link_token)

  def sign_in_url(app_url, link_token) do
    String.trim_trailing(app_url, "/") <> "/auth/device?" <> URI.encode_query(token: link_token)
  end
end
