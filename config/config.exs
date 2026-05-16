import Config

config :pageless,
  ecto_repos: [Pageless.Repo],
  generators: [timestamp_type: :utc_datetime],
  mcp_filesystem: :disabled

config :pageless, PagelessWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  url: [host: "localhost"],
  render_errors: [
    formats: [html: PagelessWeb.ErrorHTML, json: PagelessWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pageless.PubSub

# Session + LiveView signing salts. Dev/test env defaults live in dev.exs /
# test.exs; prod values come from SESSION_SIGNING_SALT / LIVE_VIEW_SALT env
# vars and are required at runtime (see config/runtime.exs).

config :phoenix, :json_library, Jason

# esbuild — bundles `assets/js/app.js` to `priv/static/assets/app.js`.
config :esbuild,
  version: "0.21.5",
  pageless: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# tailwind — compiles `assets/css/app.css` to `priv/static/assets/app.css`.
config :tailwind,
  version: "3.4.14",
  pageless: [
    args:
      ~w(--config=tailwind.config.js --input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ]

import_config "#{config_env()}.exs"
