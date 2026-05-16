# lib/pageless/proc/investigator/

Helper modules extracted from `Pageless.Proc.Investigator` to keep the parent GenServer under the project's <500 LOC module-size cap. Two independent splits converged on overlapping helpers; the duplicates section below flags consolidation candidates.

## Modules

- `Pageless.Proc.Investigator.Profile` (`profile.ex`): profile struct + `from_yaml/2` + `build_gemini_function_schema/2`. Per-profile `tool_scope` map (`kubectl`/`query_db`/`prometheus_query`/`mcp_runbook`), step limit, output schema, prompt template.
- `Pageless.Proc.Investigator.ScopeGuard` (`scope_guard.ex`) **and** `Pageless.Proc.Investigator.ProfileScope` (`profile_scope.ex`): both implement pre-gate profile-scope check. Parallel-refactor duplicates — keep the one the parent module wires; the unused one is dead code marked for follow-up cleanup. `ScopeGuard.tool_call_in_profile_scope?/3` returns `:ok | {:error, reason}`; `ProfileScope.allowed?/3` returns the same shape with `{:out_of_scope_tool, atom}` / `{:verb_not_in_profile, String.t}` / `{:table_not_in_profile_allowlist, String.t}`.
- `Pageless.Proc.Investigator.Events` (`events.ex`): agent-state append + PubSub broadcast + parent notify. Operates on a duck-typed state map with `:alert_id`, `:agent_id`, `:profile`, `:pubsub`, `:audit_repo`, `:sequence`, `:parent`. `Events.append/3` is the single write path for `AgentState.append_event/2` and advances `state.sequence`; `Events.broadcast/2` sends on the per-alert topic `"alert:#{alert_id}"`.
- `Pageless.Proc.Investigator.Audit` (`audit.ex`): terminal audit-row helpers. `record_terminal/5` writes `profile_violation` / `budget_exhausted` rows; `record_unknown_tool/3` writes the fallback row for unknown function names. Delegates argument encoding to `ToolArgs.encode/2` and classification fallback to `best_effort_classify/3`.
- `Pageless.Proc.Investigator.Gemini` (`gemini.ex`): builds streaming Gemini options (`opts/5`), renders the EEx investigation prompt (`render_prompt/2`), and decodes the final-text findings (`decode_findings/1`).
- `Pageless.Proc.Investigator.Prompt` (`prompt.ex`): non-streaming prompt + Gemini call shape. `render/1` (EEx of `profile.prompt_template` × alert envelope), `gemini_opts/1`, `continue/3` (append tool result for next turn).
- `Pageless.Proc.Investigator.ToolArgs` (`tool_args.ex`): per-tool function-call arg normalizer + audit-row encoder. `normalize/2` returns `{:ok, normalized_args} | {:error, {:malformed_tool_args, tool}}` for `:kubectl` / `:prometheus_query` / `:query_db` / `:mcp_runbook`. `encode/2` shapes normalized (or `{:malformed, raw_args}`) into the JSONB shape `audit_trail_decisions.args` expects.
- `Pageless.Proc.Investigator.JsonSafe` (`json_safe.ex`): single recursive `convert/1` — atoms → strings, tuples → lists, maps → string-keyed maps, lists recurse, scalars pass through. Used for every audit/AgentState payload + reason field across the investigator path.

## Duplicates flagged for follow-up cleanup

The parallel refactors produced overlapping submodules. Consolidation queued (not blocking — both compile, the parent module picks one):

- `ScopeGuard` ↔ `ProfileScope` — same predicate, two implementations. Pick one canonical form during the next investigator touch.
- `Gemini` (streaming) ↔ `Prompt` (non-streaming) — adjacent concerns; the investigator may use both depending on path, but the boundary is worth tightening once.
- `Events` ↔ `Audit` — broadcast/audit-write helpers; `Events` covers broader event mirroring, `Audit` is specifically terminal-row helpers. Keep both, but make the boundary explicit.

## Single canonical implementations (no duplication)

- Audit argument encoding: `ToolArgs.encode/2` only.
- JSON-safe reshape: `JsonSafe.convert/1` only.

## Patterns

- Helpers are pure module-level public functions with `@spec`; the parent GenServer's state struct is passed in (not the module itself).
- No state, no processes, no PubSub topic ownership beyond `state.pubsub`.

## Dependencies

- `Pageless.Config.Rules` (verb-table for `Audit.best_effort_classify/3` kubectl fallback).
- `Pageless.Governance.SqlSelectOnlyParser` (`ProfileScope` query_db table-list extraction).
- `Pageless.Governance.VerbTableClassifier` (`ProfileScope` kubectl verb extraction; `Audit` kubectl classification fallback).
