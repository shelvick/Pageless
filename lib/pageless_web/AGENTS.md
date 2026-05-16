# lib/pageless_web/

Phoenix web tier: endpoint, router, plugs, controllers, LiveView, components.

## Top-level modules

- `PagelessWeb.Endpoint` (`endpoint.ex`): Phoenix endpoint. Plug chain includes two trust-boundary XFF plugs in this order: `:keep_rightmost_x_forwarded_for` → `:rewrite_x_forwarded_for` (the `Plug.RewriteOn` adapter). Both share the `:pageless, :trust_x_forwarded_for` runtime gate (false in dev/test, true in `:prod` only behind Caddy). `session_options/0` is the function-form runtime resolver consumed by the `:session_plug` wrapper; signing salt comes from `Application.get_env(:pageless, :session_signing_salt)`.
- `PagelessWeb.Router` (`router.ex`): pipelines `:webhooks_public`, `:webhooks_signed`, `:demo`. Webhook rate limiting via `PagelessWeb.Plugs.WebhookRateLimit`. The `/demo/fire-test-alert` route goes through the gated kubectl flow.

## XFF trust boundary (as-built)

Two-stage normalization, both stages gated by `:trust_x_forwarded_for`:

1. `:keep_rightmost_x_forwarded_for` — joins any multi-value `x-forwarded-for` header, splits on `,`, trims, drops empties, replaces the request header with the last non-empty entry. No-op when trust is off, header is absent, or every entry is empty.
2. `:rewrite_x_forwarded_for` — wraps `Plug.RewriteOn [:x_forwarded_for]`. Reads the now single-entry header and writes `conn.remote_ip`.

Pairs with `deploy/Caddyfile` `header_up X-Forwarded-For {remote_host}` inside each `reverse_proxy 127.0.0.1:4040 { ... }` upstream block — Caddy overwrites client-supplied XFF with its own peer view, so the rightmost entry is always Caddy's view of the originating client.

## Subdirectories

- `plugs/` — `RawBodyReader`, `WebhookRateLimit`, `PagerDutyHMACVerify`, `InjectPubSub`.
- `controllers/` — Alertmanager webhook, PagerDuty webhook, Fire-test-alert demo.
- `live/` — Operator dashboard LiveView + components.
- `components/` — `Pageless.Components` shared HEEx.

## Patterns

- Endpoint accepts a per-call `trust_x_forwarded_for: true|false` opt for test injection (overrides the runtime config).
- All session state is cookie-based; no Plug.Session ETS table.
- POST body cap is 256 KB → 413 plain-text response from `PLUG_RawBodyReader`.
