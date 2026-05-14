# lib/pageless/

Top-level Pageless application modules.

## Subdirectories

- `audit_trail/` — audit trail schema + behaviour for `audit_trail_decisions`.
- `config/` and `config/rules/` — `pageless.yaml` loader + supervised Agent.
- `governance/` — capability gate, classifiers, parser, tool-call envelope.

## Top-level modules

- `Pageless.Application` (`application.ex`): OTP application root supervisor. Children: `Pageless.Repo`, `Phoenix.PubSub` (named `Pageless.PubSub`), `{Pageless.Config.Rules.Agent, path: rules_path()}`, `PagelessWeb.Endpoint`. `rules_path/0` resolves `Application.get_env(:pageless, :rules_path)` first (test override) then `Path.join(:code.priv_dir(:pageless), "pageless.yaml")`.
- `Pageless.Repo` (`repo.ex`): Ecto Repo for Postgres.
- `Pageless.AuditTrail` (`audit_trail.ex`): public audit trail API. `@behaviour Pageless.AuditTrail.Behaviour`. Functions: `record_decision/1`, `get_by_gate_id/1`, `update_decision/2`, `claim_gate_for_approval/2`, `claim_gate_for_denial/3`. Atomic claims wrap a `Repo.transaction` around a `lock: "FOR UPDATE"` query plus conditional update on `decision == "gated"`.

## Application supervisor wiring (as-built)

```
Pageless.Supervisor (one_for_one)
├── Pageless.Repo
├── Phoenix.PubSub (name: Pageless.PubSub)
├── Pageless.Config.Rules.Agent (path: priv/pageless.yaml)
└── PagelessWeb.Endpoint
```

Pending children (added per Change Set): `SVC_GeminiClient`, `SVC_MCPClient`, `SUP_AlertTree`.

## Concurrency / test-isolation conventions

- No named GenServers in supervisor children except the framework-required ones (`Pageless.PubSub`, `Pageless.Repo`, `PagelessWeb.Endpoint`).
- Rules Agent is started unnamed — defensively drops `:name` opt if passed.
- PubSub instances in tests are per-test (`start_supervised!({Phoenix.PubSub, name: unique_atom("pubsub")})`); production uses the global `Pageless.PubSub`.

## Dependencies (governance stack)

- `pg_query_ex` (NIF for SQL parsing).
- `yaml_elixir` (rules loader).
- `Jason` (encode/decode `result_summary` envelope and audit jsonb).
- `ecto_sql` + `postgrex` (`Pageless.Repo`).
- `phoenix_pubsub` (broadcast topics).
- `hammox` (test-only; `Pageless.AuditTrailMock`).
