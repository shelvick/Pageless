# lib/pageless/proc/remediator/

Helper modules extracted from `Pageless.Proc.Remediator` to keep the parent GenServer under the project's <500 LOC module-size cap. Two independent splits converged on overlapping helpers; the duplicates section below flags consolidation candidates.

## Modules

- `Pageless.Proc.Remediator.Proposal` (`proposal.ex`): typed proposal builder + event-payload shaper + tool declaration. Surface: `build/1`, `payload/1`, `tool_call/4`, `tool_definition/0`.
  - `build/1` — parses Gemini function-call args into `%{action, args, classification_hint, rationale, considered_alternatives, request_id}`. Coerces action to whitelisted atom (`:rollout_undo | :rollout_restart | :scale_down | :delete | :apply | :exec | :other`) and classification_hint to capability class (`:read | :write_dev | :write_prod_low | :write_prod_high`), falling back conservatively when input is malformed. Validates non-empty `args` (binary list) and non-empty `considered_alternatives` (each entry `%{"action" => binary, "reason_rejected" => binary}`). Defaults missing rationale to `"No rationale provided."`. Mints a `"rem_req_" <> 16-hex-byte` request id. Rejects malformed shapes with `{:error, :invalid_proposal | :invalid_args | :invalid_considered_alternatives}`.
  - `payload/1` — drops `request_id`, keeps the operator-visible fields used by `:remediator_action_proposed` broadcasts and the `:findings` agent-state row.
  - `tool_call/4` — builds the gated kubectl `ToolCall` envelope; injects `Ecto.UUID.generate/0` for `agent_id` and `findings_link/1` for evidence.
  - `tool_definition/0` — the Gemini function declaration with `minItems: 1` on `args` and `considered_alternatives`, plus the enum constraint on `classification_hint`.
- `Pageless.Proc.Remediator.Gemini` (`gemini.ex`): Gemini option builder + reasoning protocol. `opts/2`, `system_instruction/0`, `propose_action_tool/0`, `envelope_summary/1`, `findings_summary/1`. Includes `tool_choice: {:specific, "propose_action"}` for the one-shot Gemini generate call.
- `Pageless.Proc.Remediator.Prompt` (`prompt.ex`): Gemini call shape + envelope rendering. `gemini_opts/2` (Pro, non-streaming, forced function call), `envelope_summary/1`, `findings_summary/1`, `findings_link/1`, plus the system-instruction string emphasizing the Option-B "must consider alternatives" contract.

## Duplicates flagged for follow-up cleanup

`Gemini` ↔ `Prompt` overlap on `envelope_summary/1` + `findings_summary/1` + Gemini-opts construction. Both compile; the parent module picks one path. Consolidation queued for the next remediator touch.

## Constants

- `@valid_actions ~w(rollout_undo rollout_restart scale_down delete apply exec other)a` (in `Proposal`).
- `@valid_classes ~w(read write_dev write_prod_low write_prod_high)a` (mirrored — `Proposal` uses it to validate inbound atoms, `Gemini`/`Prompt` use it for the JSON schema enum).

## Single canonical implementations (no duplication)

- Proposal-payload validation and tool-declaration shape: `Proposal` only.

## Patterns

- All public surface has `@doc` + `@spec`.
- No state, no processes; pure functional transforms over Gemini args / envelopes / findings.

## Dependencies

- `Pageless.AlertEnvelope` (envelope summary).
- `Pageless.Config.Rules` (read by the parent remediator; helpers receive the proposal/envelope already extracted).
