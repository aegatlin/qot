defmodule Qot.Accounts.Mailer do
  @moduledoc """
  Email for authentication (device sign-in links).
  """

  use Swoosh.Mailer, otp_app: :qot
  import Swoosh.Email

  @doc """
  Emails the link that opens the device sign-in page. The code to type there
  is shown only on the device, never in the email.
  """
  def send_device_login(email, link_token) do
    url = QotWeb.Endpoint.url() <> "/auth/device?token=" <> link_token

    new()
    |> to(email)
    |> from({"Quantum of Thought", "noreply@quantumofthought.com"})
    |> subject("Sign in to Quantum of Thought")
    |> html_body("""
    <html>
      <body>
        <h2>Sign in to Quantum of Thought</h2>
        <p>Open this link, then enter the code shown on the device you are signing in:</p>
        <p><a href="#{url}">Continue signing in</a></p>
        <p>The link expires in 15 minutes. If you didn't just try to sign in, ignore this email.</p>
      </body>
    </html>
    """)
    |> text_body("""
    Sign in to Quantum of Thought

    Open this link, then enter the code shown on the device you are signing in:
    #{url}

    The link expires in 15 minutes. If you didn't just try to sign in, ignore this email.
    """)
    |> deliver_email()
  end

  # Dev logs emails (Swoosh.Adapters.Logger), test captures them, prod uses Resend.
  defp deliver_email(email), do: deliver(email)
end
