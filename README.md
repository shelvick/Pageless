# Pageless

**Autonomous incident response that knows when to ask.**

Multi-agent on-call system: per-alert agent trees investigate in parallel, propose remediation, and gate write actions by capability class. Built for the Milan AI Agent Olympics hackathon (May 13–19, 2026).

## Stack

Phoenix 1.8 · LiveView 1.1 · Bandit · Ecto / Postgres · gemini_ex (Gemini Flash + Pro) · Vultr Kubernetes Engine

## Status

🚧 Under active development. Live demo URL: TBD.

## Implemented seams

- Operator dashboard: `/` renders the LiveView shell on port 4040 with alert intake, agent-tree placeholder, scoreboard, and approval modal for gated actions.
- Webhook intake: `POST /webhook/alertmanager` and `POST /webhook/pagerduty-events-v2` normalize to `Pageless.AlertEnvelope` and broadcast `{:alert_received, envelope}` on PubSub.
- Supervision spine: alert broadcasts spawn per-alert supervisors; Triager and Escalator agents use explicit `kick_off/1` activation after setup.
- Governance and tools: capability gate + verb classifier + SELECT-only parser are backed by `priv/pageless.yaml`; `Pageless.Tools.Kubectl` executes approved real `kubectl` calls.
- Data foundation: deploy ledger seed row for the B4 demo SQL, audit trail rows for gate decisions, and append-only `agent_state_events` for agent traces.
- Drift prevention: `Pageless.Conductor.BeatModeRegistry`, `[CONDUCTOR]` badge component, and `mix demo.check` pre-record gate.
- Gemini adapter: `Pageless.Svc.GeminiClient` wraps `gemini_ex` behind an injectable Hammox behaviour and mailbox stream contract.
- MCP consume path: `Pageless.Svc.MCPClient` + schema translator normalize filesystem-server tools for future runbook reads; optional MCP supervision is disabled by default.

## Local development

Requires Elixir 1.18+ / OTP 27 and PostgreSQL 17. The Phoenix endpoint runs on port **4040** (not 4000).

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
mix phx.server
```

Then visit <http://localhost:4040>.
