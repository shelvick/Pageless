# test/pageless/governance/

Tests for the capability gate, classifiers, and parser. All `async: true`.

## Files

- `capability_gate_test.exs` — `Pageless.Governance.CapabilityGate`. Covers R1-R28 (functional), uses Sandbox + Hammox.
- `verb_table_classifier_test.exs` — `Pageless.Governance.VerbTableClassifier`. Pure-function unit tests plus a StreamData property (`R21`) for unknown verbs.
- `sql_select_only_parser_test.exs` — `Pageless.Governance.SqlSelectOnlyParser`. Pure-function unit tests plus a StreamData property (`R36`) for non-SELECT statements.

## Setup patterns (capability gate)

- `setup :verify_on_exit!` (Hammox).
- `setup` builds:
  - `sandbox_owner = Sandbox.start_owner!(Repo, shared: false)` with matching `on_exit(fn -> Sandbox.stop_owner(sandbox_owner) end)`.
  - Per-test `pubsub = unique_atom("gate_pubsub")` started with `start_supervised!({Phoenix.PubSub, name: pubsub})`.
  - Loads default rules via `Rules.load!("test/fixtures/pageless_rules/default.yaml")`.

## Test helpers (capability gate)

- `opts(pubsub, dispatch, overrides \\ [])` — builds the gate opts keyword. Default `repo: AuditTrail`; pass `repo: Pageless.AuditTrailMock` in failure-path tests.
- `tool_call/3`, `rollout_undo_call/1` — build `%ToolCall{}` envelopes.
- `decision_fixture/1` — builds an in-memory `%Decision{}` for mock returns. Honors `result_summary` so legacy/nested context tests can exercise the decode path.
- `unique_atom/1`, `unique/1` — `System.unique_integer([:positive])`-suffixed identifiers.

## Concurrency tests (R10, R11, R20)

- Spawn `Task.async` children; pass `sandbox_owner` into each task; call `Sandbox.allow(Pageless.Repo, sandbox_owner, self())` inside the task before any Repo work.
- Use `make_ref()` + `assert_receive {^release_ref, :go}` barriers to coordinate task start. Never `Process.sleep` for synchronization.

## Hammox usage

- Mock module: `Pageless.AuditTrailMock` (Behaviour: `Pageless.AuditTrail.Behaviour`).
- Used for record-failure, update-failure, approve-claim-failure, deny-claim-failure, forced gate-id-collision retry, and legacy/nested reasoning-context decode paths.

## Discipline checks (R29/R30)

- `async: true` declared on the test header (file line 4). Credo high-priority `TestsWithoutAsync` blocks any regression at commit time.
- No runtime introspection tests for `start_link/1` absence — enforcement is structural via Credo `NoNamedGenServers`/`NoNamedEtsTables`.

## Fixtures used

- `test/fixtures/pageless_rules/default.yaml` — shipping defaults; matches `priv/pageless.yaml`.
