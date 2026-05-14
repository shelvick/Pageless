# test/pageless/

Tests for `lib/pageless/` modules.

## Subdirectories

- `config/` — `Pageless.Config.Rules` and the supervised Agent.
- `governance/` — capability gate, classifiers, parser. The TDD heart.

## Top-level test files

- `audit_trail_test.exs` — Integration tests for `Pageless.AuditTrail` against real Postgres via `Sandbox.start_owner!`. Covers schema + state-machine validation (R1-R25 from `noderr/specs/DATA_AuditTrailRepo.md`). Concurrent claim tests pass `sandbox_owner` into each `Task.async` and call `Sandbox.allow/3` before any Repo work.

## Conventions

- All tests `async: true`. `async: false` is forbidden; if isolation seems impossible, find the global-state leak instead.
- Per-test sandbox owner via `Sandbox.start_owner!(Pageless.Repo, shared: false)` + matching `on_exit(fn -> Sandbox.stop_owner(...) end)`.
- Spawned GenServers/Agents get the 3-step cleanup pattern (init wait → `on_exit` registered immediately → `:infinity` `GenServer.stop`).
- `unique_atom/1` / `unique/1` helpers (defined locally per test module) for collision-free names using `System.unique_integer([:positive])`.

## Hammox usage

- `Pageless.AuditTrailMock` (Behaviour: `Pageless.AuditTrail.Behaviour`) — used in `governance/capability_gate_test.exs` for repo-failure paths.
