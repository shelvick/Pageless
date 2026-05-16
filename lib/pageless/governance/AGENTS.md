# lib/pageless/governance/

Capability-gating policy engine for agent-emitted tool calls. Stateless modules, no GenServers, no global state.

## Modules

- `Pageless.Governance.CapabilityGate` (`capability_gate.ex`): policy engine. Classifies, audits, dispatches.
- `Pageless.Governance.ToolCall` (`tool_call.ex`): envelope struct. `@enforce_keys [:tool, :args, :agent_id, :alert_id, :request_id]`. `reasoning_context: map()` defaults `%{}`.
- `Pageless.Governance.VerbTableClassifier` (`verb_table_classifier.ex`): kubectl `args -> {:ok, class, verb}` lookup.
- `Pageless.Governance.SqlSelectOnlyParser` (`sql_select_only_parser.ex`): structural SQL validator over `pg_query_ex`.

## CapabilityGate API

- `request(%ToolCall{}, %Rules{}, opts) :: {:ok, term} | {:gated, gate_id} | {:error, atom | tuple}`
- `approve(gate_id, operator_ref, opts) :: {:ok, term} | {:error, approve_error}`
- `deny(gate_id, operator_ref, reason, opts) :: :ok | {:error, atom}`

Required opts on every call: `tool_dispatch: (ToolCall.t -> {:ok, term} | {:error, term})`, `pubsub: atom`, `repo: module`. Optional `reply_to: pid()` for `{:gate_result, gate_id, ...}` async delivery.

## Classifier dispatch (kubectl → VerbTableClassifier, query_db → SqlSelectOnlyParser, prometheus_query/mcp_runbook → :read direct)

- Unknown tool → `{:error, :unknown_tool}` (no audit row).
- Classifier `{:error, reason}` → conservative-class rejection row (`"read"` for SQL, `"write_prod_high"` for kubectl), `{:error, reason}`.

## Audit lifecycle (state machine, stored in `decision` column)

- `execute / audit_and_execute / gated / rejected` → initial decision
- `gated → approved | denied`
- `approved | execute | audit_and_execute → executed | execution_failed`
- Other transitions blocked by `Decision.changeset/2`.

## Reasoning-context envelope on `result_summary`

- Module attribute `@context_metadata_prefix "pageless:gate-context:"`.
- `encode_context_metadata/1`: prefix + `Jason.encode!(%{"reasoning_context" => context})`.
- `decode_context/1`: prefix-aware. Falls back to plain JSON decode for legacy rows. Recursively normalizes string keys via `String.to_existing_atom/1` (rescued `ArgumentError` → keep as string). Handles maps nested in lists.
- Non-prefixed reason strings (`":policy_denied"`, `":not_select"`) decode cleanly to `%{}`.

## Policy-denied path

- `auto: false, gated: false` policy → single insert with `decision="rejected"` + `result_status="error"` + `result_summary=":policy_denied"`. No follow-up update.

## Gate ID handling

- Generated only for `:write_prod_high` paths: `"gate_" <> :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)`.
- 64-bit entropy. On unique-index collision, retries up to 3 times then `{:error, :gate_id_collision}`.
- Atomic approval/denial via `AuditTrail.claim_gate_for_approval/2` and `claim_gate_for_denial/3` (transaction + `FOR UPDATE`).

## PubSub topic convention

- Always `"alert:#{tool_call.alert_id}"` on `opts[:pubsub]`.
- Events: `{:gate_fired, gate_id, tool_call, class, verb, reasoning_context}`, `{:gate_decision, event_atom, ...}`, `{:gate_result, gate_id, result}` (if `reply_to`).

## VerbTableClassifier specifics

- `classify/2` and `extract_verb/1`. Strips recognized leading kubectl flags before verb extraction (`-n`, `--namespace`, `--context`, `--cluster`, `--user`, `--kubeconfig`, `--as`, `--as-group`, `--request-timeout`, `--all-namespaces`, `-A`, `--verbose`, `--v`, `--quiet`, inline `--flag=value` form).
- Compound rollout: `["rollout" | rest]` → strips leading flags inside `rest` before picking subcommand.
- Scale direction inferred from `--replicas=±N` (synthetic verbs `"scale-up"`/`"scale-down"`); absolute `N` keeps verb `"scale"` (fail-closed default).
- Replicas magnitude pass (verb-conditional, fires only on `"scale"`): single private `classify_scale_verb/2` runs `extract_replicas/1` (collect-all, reject multi/dangling as `:malformed_args`), an `Integer.parse/1` strict value check, and the symmetric magnitude check (`@replicas_max_delta = 10` on `±N`, `@replicas_max_absolute = 20` on unsigned `N`). Out-of-bound rejects with `{:forbidden_replicas, raw_value :: String.t()}`; non-integer values reject as `:malformed_args`. Then `infer_scale_direction/1` synthesizes `"scale-up"` / `"scale-down"` / `"scale"` from the validated value.
- Unknown verbs / unknown compounds → `:write_prod_high` (fail-closed default).
- Verb table is data, not hardcoded. `%Rules{}.kubectl_verbs` injected by caller. Magnitude caps are hardcoded module attributes (no YAML).

## SqlSelectOnlyParser specifics

- Backed by `PgQuery.parse/1` NIF.
- Empty/whitespace → `:empty`. Parse failure → `:parse_failure`. Multi-statement → `:multiple_statements`. Non-SELECT top-level → `:not_select`. `SELECT INTO`, `FOR UPDATE`/`FOR SHARE`/`FOR NO KEY UPDATE`/`FOR KEY SHARE` (including nested) → `:not_select`. Data-modifying CTE bodies → `:not_select`. `EXPLAIN ANALYZE` (incl. `EXPLAIN (ANALYZE)` / `EXPLAIN (ANALYZE true)`) → `:not_select`.
- Function blocklist: case-insensitive match on full-qualified or final-segment name. Returns `{:state_modifying_function, name}` on first hit (depth-first).

## Dependencies

- `Pageless.AuditTrail.Behaviour` (via injected `:repo` opt; production `Pageless.AuditTrail`, tests `Pageless.AuditTrailMock`).
- `Pageless.Config.Rules` (`%Rules{}` struct passed explicitly; no globals).
- `Phoenix.PubSub` (injected `:pubsub` atom).
- `pg_query_ex`, `Jason`, `:crypto`, `Base`.
