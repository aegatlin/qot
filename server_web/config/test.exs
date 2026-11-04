import Config

config :qot, Qot.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER"),
  password: System.get_env("PGPASSWORD") || "",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "qot_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :qot, QotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_testing_only_use_here",
  server: false

# Use test adapter for emails (doesn't actually send)
config :qot, Qot.Accounts.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# A fixed signer so tests never depend on the environment.
config :joken, default_signer: "test-only-jwt-signing-key"

# Every test shares one limiter and one client IP, so the real limits would
# make tests fail depending on what else ran. Tests of the limits start their
# own limiter or set lower ones.
config :qot, :sign_in_limits, %{email: {1000, 3600}, ip: {1000, 3600}}
