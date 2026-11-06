import Config

config :qot, Qot.Accounts.Mailer, adapter: Swoosh.Adapters.Resend

config :swoosh, :api_client, Swoosh.ApiClient.Req

config :logger, level: :info
