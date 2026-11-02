import Config

config :qot, :cors_origins, []

config :qot, QotWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :qot, Qot.Accounts.Mailer, adapter: Swoosh.Adapters.Resend

config :swoosh, :api_client, Swoosh.ApiClient.Req

config :logger, level: :info
