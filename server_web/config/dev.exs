import Config

# The PWA's dev server (`mise run dev:web`); APP_URL overrides it.
config :qot, :app_url, "http://localhost:5173"

config :qot, Qot.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER"),
  password: System.get_env("PGPASSWORD") || "",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "qot_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :qot, QotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_at_least_64_bytes_long_for_development_only_use",
  watchers: []

# Dev prints emails (sign-in links included) to the server log.
config :qot, Qot.Accounts.Mailer, adapter: Swoosh.Adapters.Logger, log_full_email: true

config :swoosh, :api_client, false

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :joken, default_signer: System.get_env("JWT_SECRET_KEY", "dev-only-jwt-signing-key")
