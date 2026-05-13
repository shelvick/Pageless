import Config

# Runtime configuration. Populated Day 1+ as env vars get wired.
# Expected env vars at production:
#   SECRET_KEY_BASE       - Phoenix session secret (>=64 chars)
#   DATABASE_URL          - Vultr Managed PG connection string
#   GEMINI_API_KEY        - Google AI Studio key
#   KUBECONFIG            - Path to VKE kubeconfig (after base64 decode)
#   PAGERDUTY_ROUTING_KEY - PD Events v2 routing key
#   PHX_HOST              - Public hostname

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL not set"
  config :pageless, Pageless.Repo, url: database_url, pool_size: 10

  secret = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE not set"
  host = System.get_env("PHX_HOST") || raise "PHX_HOST not set"

  config :pageless, PagelessWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4040")
    ],
    secret_key_base: secret
end
