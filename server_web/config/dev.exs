import Config

config :qot, :cors_origins, ["http://localhost:5173", "http://localhost:5174"]

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
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_at_least_64_bytes_long_for_development_only_use",
  watchers: []

config :qot, Qot.Accounts.Mailer, adapter: Swoosh.Adapters.Local

config :swoosh, :api_client, Swoosh.ApiClient.Req

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
