# test/pageless_web/

Tests for `lib/pageless_web/`.

## Top-level test files

- `endpoint_test.exs` — `PagelessWeb.Endpoint` smoke tests + the two-stage XFF trust-boundary regression suite (R1–R12 of `WG-XFFRightmost`). Covers the `:keep_rightmost_x_forwarded_for` plug branches (R1–R8, UNIT), the `Endpoint.call/2` integration with `trust_x_forwarded_for: true|false` (R9–R10), and a deploy-artifact regex check on `deploy/Caddyfile` (R12). The acceptance test (R11) lives in `controllers/fire_test_alert_controller_test.exs`.

## Subdirectories

- `controllers/` — webhook + demo controller tests.
- `live/` — operator dashboard LiveView tests.
- `plugs/` — plug-level tests (rate limit, HMAC verify, raw body).
- `components/` — function-component tests.

## Conventions

- All tests `async: true`. Endpoint tests use `Phoenix.ConnTest.build_conn` + `Map.put(:remote_ip, ...)` to simulate the TCP peer, then `Endpoint.call(conn, trust_x_forwarded_for: true|false)` to opt-inject the trust flag per-test (no `Application.put_env`).
- No `Process.sleep` anywhere; rate-limit acceptance tests use `burst: 1` configurations for synchronous exhaustion.
- Deploy-artifact tests read `deploy/Caddyfile` from disk (relative to `__DIR__`) and regex-match the expected directive — keeps the structural assertion local to the test file.
