# lib/pageless/config/rules/

Agent wrapper around `Pageless.Config.Rules`.

## Modules

- `Pageless.Config.Rules.Agent` (`agent.ex`): thin `use Agent` wrapper. Started by `Pageless.Application` supervisor with `{Pageless.Config.Rules.Agent, path: rules_path()}`.

## API

- `start_link(opts)` — `opts: [path: Path.t()]`. Defensively drops any `:name` key from opts: the Agent is unnamed by design (test isolation, no global registration).
- `get(pid) :: Pageless.Config.Rules.t()` — returns the loaded struct.

## Boot semantics

- Calls `Pageless.Config.Rules.load!/1` synchronously during `Agent.start_link/1`. Any raise propagates through the supervisor restart loop and prevents Phoenix from booting (fail-closed boot for misconfigured rules).
- Returned PID is opaque; downstream callers receive it via explicit injection (or — once introduced in a later Change Set — via a Registry lookup).

## Dependencies

- Owns a `Pageless.Config.Rules.t()` value at runtime. No DB, no PubSub, no other Agents.
