import Config

config :qot, ecto_repos: [Qot.Repo]

config :qot, Qot.Repo, migration_timestamps: [type: :utc_datetime]

config :qot, QotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: QotWeb.ErrorJSON], layout: false],
  pubsub_server: Qot.PubSub

config :joken, default_signer: System.get_env("JWT_SECRET_KEY")

import_config "#{config_env()}.exs"
