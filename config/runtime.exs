import Config

# Runtime configuration. Populated Day 1+ as env vars get wired.
# Expected env vars at production:
#   SECRET_KEY_BASE          - Phoenix session secret (>=64 chars)
#   DATABASE_URL             - Vultr Managed PG connection string
#   GEMINI_API_KEY           - Google AI Studio key
#   KUBECONFIG               - Path to VKE kubeconfig (after base64 decode)
#   PAGERDUTY_ROUTING_KEY    - PD Events v2 routing key
#   PHX_HOST                 - Public hostname
#   ALERT_TREE_MAX_CHILDREN  - Per-supervisor cap on simultaneous alert trees (default 10)
#   SESSION_SIGNING_SALT     - Plug.Session cookie signing salt (required in :prod)
#   LIVE_VIEW_SALT           - Phoenix LiveView signing salt (required in :prod)
#   WEBHOOK_PD_HMAC_SECRET   - PagerDuty webhook signing secret (required in :prod)
#   GEMINI_DAILY_CALL_CAP    - Daily Gemini API call cap (required in :prod)

# Honored in all envs so devs can lower the cap for local load testing.
config :pageless,
       :gemini_daily_call_cap,
       String.to_integer(System.get_env("GEMINI_DAILY_CALL_CAP") || "5000")

config :pageless,
       :alert_tree_max_children,
       String.to_integer(System.get_env("ALERT_TREE_MAX_CHILDREN") || "10")

config :pageless,
       :webhook_dedup_window_ms,
       String.to_integer(System.get_env("WEBHOOK_DEDUP_WINDOW_MS") || "60000")

# Session + LiveView signing salts. Honored in all envs; fall through to
# dev.exs / test.exs defaults when the env var is not set in non-prod.
if salt = System.get_env("SESSION_SIGNING_SALT") do
  config :pageless, :session_signing_salt, salt
end

if salt = System.get_env("LIVE_VIEW_SALT") do
  config :pageless, PagelessWeb.Endpoint, live_view: [signing_salt: salt]
end

if secret = System.get_env("WEBHOOK_PD_HMAC_SECRET") do
  config :pageless, :pagerduty_webhook_secret, secret
end

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL not set"
  config :pageless, Pageless.Repo, url: database_url, pool_size: 10
  config :pageless, :trust_x_forwarded_for, true

  secret = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE not set"
  host = System.get_env("PHX_HOST") || raise "PHX_HOST not set"

  System.get_env("SESSION_SIGNING_SALT") || raise "SESSION_SIGNING_SALT not set"
  System.get_env("LIVE_VIEW_SALT") || raise "LIVE_VIEW_SALT not set"
  System.get_env("WEBHOOK_PD_HMAC_SECRET") || raise "WEBHOOK_PD_HMAC_SECRET not set"
  System.get_env("GEMINI_DAILY_CALL_CAP") || raise "GEMINI_DAILY_CALL_CAP not set"

  # Bind to loopback only; Caddy reverse-proxy fronts public traffic and is the
  # sole place webhook IP-allowlisting is enforced. Binding to 0.0.0.0 would
  # let attackers bypass Caddy by hitting http://<vm-ip>:4040/webhook/* directly.
  config :pageless, PagelessWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {127, 0, 0, 1},
      port: String.to_integer(System.get_env("PORT") || "4040")
    ],
    secret_key_base: secret
end
