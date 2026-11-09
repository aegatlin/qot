import Config

# bin/server sets PHX_SERVER so the release starts the endpoint; `bin/qot eval`
# tasks such as migrations don't.
if System.get_env("PHX_SERVER") do
  config :qot, QotWeb.Endpoint, server: true
end

# The deployed commit, reported by /health. Railway sets this on every deploy.
config :qot, :commit, System.get_env("RAILWAY_GIT_COMMIT_SHA")

# Where the PWA lives (QotWeb.AppOrigin): sign-in links open it, and its
# origin may call the API. Required in production; dev defaults to the PWA's
# dev server (config/dev.exs).
if config_env() != :test do
  case System.get_env("APP_URL") do
    nil ->
      if config_env() == :prod do
        raise "environment variable APP_URL is missing: the PWA's URL, e.g. https://app.quantumofthought.com"
      end

    "" ->
      raise "APP_URL is empty: set it to the PWA's URL, e.g. https://app.quantumofthought.com"

    url ->
      config :qot, :app_url, url
  end
end

# Sign in with Apple: the client ids an identity token may be for, comma
# separated. Optional; config.exs has the iOS app's bundle id.
case System.get_env("APPLE_CLIENT_IDS") do
  nil ->
    :ok

  ids ->
    case ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] ->
        raise "APPLE_CLIENT_IDS is empty: unset it, or list client ids, e.g. llc.abstractsyntax.qot"

      ids ->
        config :qot, :apple_client_ids, ids
    end
end

# Sign in with Apple's key (Apple's .p8 and its id), to sign the client
# secret that exchanges and revokes Apple's tokens (#88). Optional: without it
# the server signs in with Apple but can't revoke on account deletion.
case {System.get_env("APPLE_SIWA_KEY"), System.get_env("APPLE_SIWA_KEY_ID")} do
  {nil, nil} ->
    :ok

  {pem, key_id} when is_binary(pem) and pem != "" and is_binary(key_id) and key_id != "" ->
    config :qot, :apple_signing_key, %{
      team_id: System.get_env("APPLE_TEAM_ID", "H88537CLVC"),
      key_id: key_id,
      pem: pem
    }

  _ ->
    raise "set both APPLE_SIWA_KEY and APPLE_SIWA_KEY_ID, or neither"
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

  # Railway's edge proxy sets X-Real-IP to the client's address on every
  # request; elsewhere, set CLIENT_IP_HEADER to what your proxy sets.
  config :qot, :client_ip_header, System.get_env("CLIENT_IP_HEADER", "x-real-ip")

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :qot, QotWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
