import Config

config :pageless,
  ecto_repos: [Pageless.Repo],
  generators: [timestamp_type: :utc_datetime]

# Pageless uses 4040. Port 4000 is reserved for a separate live service —
# see global CLAUDE.md prime directive.
config :pageless, PagelessWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  url: [host: "localhost"],
  render_errors: [
    formats: [html: PagelessWeb.ErrorHTML, json: PagelessWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pageless.PubSub,
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SALT", "dev-only-salt-replace-prod")]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
