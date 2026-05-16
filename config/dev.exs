import Config

config :pageless, Pageless.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "pageless_dev",
  pool_size: 10,
  show_sensitive_data_on_connection_error: true

config :pageless, PagelessWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev-key-base-min-64-chars-replace-prod-replace-prod-replace-prod-replace-prod",
  live_view: [signing_salt: "dev-only-live-view-salt-replace-prod"],
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:pageless, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:pageless, ~w(--watch)]}
  ]

config :pageless, :session_signing_salt, "dev-only-session-signing-salt-replace-prod"
config :pageless, :trust_x_forwarded_for, false
config :pageless, :pagerduty_webhook_required, false

config :pageless, PagelessWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/pageless_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# Enable once a local filesystem MCP server command is installed.
config :pageless, :mcp_filesystem, :disabled
