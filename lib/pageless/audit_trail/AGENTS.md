# lib/pageless/audit_trail/

Audit trail schema + behaviour for `audit_trail_decisions` table.

## Modules

- `Pageless.AuditTrail.Decision` (`decision.ex`): Ecto schema. `@primary_key {:id, :binary_id, autogenerate: true}`. Stores one row per classified tool call; updated through its lifecycle.
- `Pageless.AuditTrail.Behaviour` (`behaviour.ex`): callbacks the gate consumes. `record_decision/1`, `get_by_gate_id/1`, `update_decision/2`, `claim_gate_for_approval/2`, `claim_gate_for_denial/3`. Hammoxed in tests via `Pageless.AuditTrailMock`.

## Schema fields

- Identity: `id`, `request_id`, `gate_id` (unique-when-not-null), `alert_id`, `agent_id`, `agent_pid_inspect`.
- Call: `tool` (`"kubectl"` / `"prometheus_query"` / `"query_db"` / `"mcp_runbook"`), `args` (jsonb map), `extracted_verb`.
- Decision: `classification`, `decision` (state column), `operator_ref`, `denial_reason`, `result_status`, `result_summary`.
- Timestamps: `inserted_at`, `updated_at` (`:utc_datetime_usec`).

## Changeset rules

- `tool` and `classification` validated against allowed lists.
- `decision` state machine (`@initial_decisions`, allowed transitions in `validate_transition/2`). Initial states: `execute / audit_and_execute / gated / rejected`. Terminal updates require `result_status` and `result_summary`.
- `gate_id` required when `decision == "gated"`.
- `operator_ref` required for `approved | denied`.
- `denial_reason` required for `denied`.
- Unique constraint on `gate_id` (partial index `WHERE gate_id IS NOT NULL`).

## Indexes (migration `priv/repo/migrations/20260513214000_create_audit_trail_decisions.exs`)

- `request_id`, `alert_id`, `agent_id`, `inserted_at`, `decision`, partial unique `gate_id`.

## Atomic claim functions

- `claim_gate_for_approval/2` and `claim_gate_for_denial/3`:
  - Wrap work in `Repo.transaction/1`.
  - Acquire row lock via `from(d in Decision, where: d.gate_id == ^gate_id, lock: "FOR UPDATE")`.
  - Verify `decision == "gated"` before applying conditional update.
  - Return `{:error, :no_pending_gate}` if the row is missing or already resolved.
  - Two concurrent claimers serialize on the row lock — exactly one wins.

## Dependencies

- `Pageless.Repo` (configured per env).
- Used by `Pageless.Governance.CapabilityGate`.
