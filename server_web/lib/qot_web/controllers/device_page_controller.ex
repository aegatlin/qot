defmodule QotWeb.DevicePageController do
  @moduledoc """
  The page an emailed sign-in link opens. Opening it approves nothing: the
  person has to type the code their device is showing.

  With a PWA (`QotWeb.AppOrigin`), links open the PWA's sign-in page instead,
  and this page sends any link that still arrives here on to it.
  """

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias Qot.Accounts

  def show(conn, %{"token" => token}) when is_binary(token) do
    if QotWeb.AppOrigin.url(),
      do: redirect(conn, external: QotWeb.AppOrigin.sign_in_url(token)),
      else: form_page(conn, token)
  end

  def show(conn, _params), do: page(conn, 404, expired())

  defp form_page(conn, token) do
    case Accounts.get_device_login_by_link(token) do
      {:ok, _login} -> page(conn, 200, form(token, nil))
      {:error, _} -> page(conn, 404, expired())
    end
  end

  def approve(conn, %{"token" => token, "user_code" => user_code}) do
    case Accounts.approve_device_login(token, user_code) do
      {:ok, _login} ->
        page(conn, 200, """
        <h1>You're signed in</h1>
        <p>You can close this page and return to your terminal.</p>
        """)

      {:error, :mismatch} ->
        page(
          conn,
          422,
          form(token, "That code doesn't match. Check your terminal and try again.")
        )

      {:error, _} ->
        page(conn, 404, expired())
    end
  end

  def approve(conn, _params), do: page(conn, 404, expired())

  defp form(token, error) do
    """
    <h1>Sign in to Quantum of Thought</h1>
    <p>Enter the code shown in your terminal (or on the device you are signing in).</p>
    #{if error, do: ~s(<p class="error">#{esc(error)}</p>), else: ""}
    <form method="post" action="/auth/device">
      <input type="hidden" name="token" value="#{esc(token)}">
      <input name="user_code" placeholder="XXXX-XXXX" autocomplete="one-time-code"
             autocapitalize="characters" spellcheck="false" autofocus required>
      <button type="submit">Sign in</button>
    </form>
    <p class="hint">If you didn't just try to sign in, close this page.</p>
    """
  end

  defp expired do
    """
    <h1>This link has expired</h1>
    <p>Sign-in links work once and for 15 minutes. Start again from your device.</p>
    """
  end

  defp page(conn, status, body) do
    conn
    |> put_status(status)
    |> html("""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Sign in · Quantum of Thought</title>
      <style>
        :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
        body { max-width: 28rem; margin: 4rem auto; padding: 0 1rem; line-height: 1.5; }
        input { font: inherit; font-size: 1.5rem; letter-spacing: .15em; text-transform: uppercase;
                width: 100%; box-sizing: border-box; padding: .5rem; margin: .5rem 0; }
        button { font: inherit; padding: .5rem 1rem; }
        .error { color: #c62828; }
        .hint { opacity: .7; font-size: .9rem; }
      </style>
    </head>
    <body>
    #{body}
    </body>
    </html>
    """)
  end

  defp esc(text), do: text |> Plug.HTML.html_escape()
end
