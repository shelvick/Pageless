import Config

config :pageless, Pageless.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "pageless_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :pageless, PagelessWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-key-base-min-64-chars-stable-across-runs-fine-not-a-real-secret-pageless-yo",
  live_view: [signing_salt: "test-only-live-view-salt-stable-across-runs"],
  server: false

config :pageless, :session_signing_salt, "test-only-session-signing-salt-stable-across-runs"
config :pageless, :trust_x_forwarded_for, false
config :pageless, :pagerduty_webhook_required, false
config :pageless, :pagerduty_webhook_secret, "test-pagerduty-secret"

config :pageless, :kubectl_impl, Pageless.Tools.Kubectl.Mock

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
