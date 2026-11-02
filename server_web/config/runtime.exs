import Config

# bin/server sets PHX_SERVER so the release starts the endpoint; `bin/qot eval`
# tasks such as migrations don't.
if System.get_env("PHX_SERVER") do
  config :qot, QotWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # TLS with certificate verification by default. DATABASE_SSL=false is for a
  # database on the host's private network (e.g. postgres.railway.internal),
  # which isn't reachable from outside and whose certificate is self-signed.
  ssl? = System.get_env("DATABASE_SSL", "true") != "false"
  socket_options = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :qot, Qot.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: ssl?,
    socket_options: socket_options

  jwt_secret_key =
    System.get_env("JWT_SECRET_KEY") ||
      raise """
      environment variable JWT_SECRET_KEY is missing.
      Generate a secure random string for production.
      """

  config :joken, default_signer: jwt_secret_key

  resend_api_key =
    System.get_env("RESEND_API_KEY") ||
      raise """
      environment variable RESEND_API_KEY is missing.
      Get your API key from https://resend.com
      """

  config :qot, Qot.Accounts.Mailer, api_key: resend_api_key

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Sign-in emails link to this host, so it must be the public one.
  host =
    System.get_env("PHX_HOST") ||
      raise "environment variable PHX_HOST is missing. Example: qot.example.com"

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :qot, QotWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
