# Pageless

**Autonomous incident response that knows when to ask.**

Multi-agent on-call system: per-alert agent trees investigate in parallel, propose remediation, and gate write actions by capability class. Built for the Milan AI Agent Olympics hackathon (May 13–19, 2026).

## Stack

Phoenix 1.8 · LiveView 1.1 · Bandit · Ecto / Postgres · Gemini (Flash + Pro) · Vultr Kubernetes Engine

## Status

🚧 Under active development. Live demo URL: TBD.

## Local development

Requires Elixir 1.18+ / OTP 27 and PostgreSQL 17. The Phoenix endpoint runs on port **4040** (not 4000).

```bash
mix deps.get
mix ecto.create
mix phx.server
```

Then visit <http://localhost:4040>.
