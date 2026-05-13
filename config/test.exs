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
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
