import Config

config :qot, ecto_repos: [Qot.Repo]

config :qot, Qot.Repo, migration_timestamps: [type: :utc_datetime]

config :qot, QotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: QotWeb.ErrorJSON], layout: false],
  pubsub_server: Qot.PubSub

# How often a sign-in may start (each one sends an email): at most `max` in
# any `window` seconds, per address and per client IP.
config :qot, :sign_in_limits, %{email: {5, 3600}, ip: {20, 3600}}

# The header a trusted proxy sets to the client's IP (see
# QotWeb.Plugs.ClientIP). Unset: the peer address is the client.
config :qot, :client_ip_header, nil

# Sign in with Apple: the client ids (bundle ids, later a Services ID for the
# web) an identity token may be for. APPLE_CLIENT_IDS overrides it at runtime.
config :qot, :apple_client_ids, ["llc.abstractsyntax.qot"]

import_config "#{config_env()}.exs"
