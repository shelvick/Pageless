# lib/pageless/proc/

Per-alert agent GenServers. Each module is spawned under the per-alert `Pageless.Sup.Alert.AgentSup` and emits events on the per-alert PubSub topic. No named processes; every PID is returned to the supervisor.

## Modules

- `Pageless.Proc.Triager` (`triager.ex`): Flash classification agent. Single-call run, emits topology + profile list. B3.
- `Pageless.Proc.Investigator` (`investigator.ex`): profile-scoped Pro reasoning agent. Tool calls route through `GATE_CapabilityGate.request/3` after a pre-gate profile-scope guard. B4. Subdirectory `investigator/` holds focused helpers (see `investigator/AGENTS.md`).
- `Pageless.Proc.Remediator` (`remediator.ex`): Pro proposal agent. Forced single function call; B5 money beat. Subdirectory `remediator/` holds focused helpers (see `remediator/AGENTS.md`).
- `Pageless.Proc.Escalator` (`escalator.ex`): Flash structured-page-out agent. Forced `page_out` function call → `SVC_ResolveClient.escalate/3`. S2 path.

## Subdirectories

- `investigator/` — investigator profile + extracted helper modules (`ScopeGuard`/`ProfileScope` for profile-scope check, `Events` for broadcast/audit emission, `Gemini` for prompting/decoding, `Prompt` for prompt building, `Audit` for audit writer, `JsonSafe` for JSON-safe reshape, `ToolArgs` for tool-arg normalization).
- `remediator/` — extracted helpers for proposal parsing (`Proposal`), prompt building (`Prompt`), and Gemini integration (`Gemini`).

## Cross-cutting agent conventions

- Lifecycle: `init/1` → `handle_continue(:setup, _)` (Sandbox.allow, broadcast `:spawned`) → `handle_call(:get_state, …)` → `handle_info(:run, _)` after `kick_off/1`.
- Sandbox: `:sandbox_owner` opt is plumbed through to `Ecto.Adapters.SQL.Sandbox.allow/3` inside `handle_continue(:setup, _)`. Never in `init/1` (race).
- Hammox allowance: `handle_call(:get_state, {caller, _}, state)` re-issues `Hammox.allow/3` for `:gemini_client` / `:gate_repo` so the test-process caller gets through behaviour mocks.
- AgentState writes: each broadcast event is mirrored to `DATA_AgentState` via `Pageless.Data.AgentState.append_event/2`, payload pre-shaped by a module-local `json_safe/1` (Investigator delegates to `Pageless.Proc.Investigator.JsonSafe.convert/1`).
- PubSub topic: always `"alert:#{alert_id}"`. Investigator events use `agent_id` prefixed by role (`"investigator-<int>"`); Remediator/Escalator use `"remediator-<int>"` / `"escalator-<int>"`.
- DI: `:gemini_client`, `:gate_module`, `:gate_repo`, `:audit_repo`, `:tool_dispatch`, `:pubsub`, `:alert_state_pid`, `:rules` are all passed via opts. No `Application.get_env/2` reads in the agent.
- Budget: every gate call is preceded by `Pageless.Sup.Alert.State.inc_tool_call/1`; `{:error, :budget_exhausted}` writes a terminal `budget_exhausted` audit row and stops the agent `:normal`.
- Module-size discipline: the submodule layout reflects a <500 LOC cap on the parent GenServers; helpers in `investigator/` and `remediator/` are the result of splitting the parents when they grew past it.

## Dependencies

- `Pageless.Svc.GeminiClient` (streamed or one-shot).
- `Pageless.Governance.CapabilityGate` for tool dispatch with audit + approval seams.
- `Pageless.Data.AgentState` for the per-event row-write model.
- `Pageless.AlertEnvelope` as the canonical alert struct fed to every agent.

## Spec mapping

- `noderr/specs/PROC_Triager.md`, `PROC_Investigator.md`, `PROC_Remediator.md`, `PROC_Escalator.md`.
