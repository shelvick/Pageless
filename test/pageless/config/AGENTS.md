# test/pageless/config/

Tests for `Pageless.Config.Rules` loader + validator.

## Files

- `rules_test.exs` — `async: true`. Covers R1-R22 from `noderr/specs/CFG_RulesYamlLoader.md`. Pure-function tests of `load!/1`, `validate!/1`, `policy_for/2`, plus two integration tests that exercise the `Pageless.Config.Rules.Agent` boot path via `start_supervised!` and a one-off `Supervisor` with `Process.flag(:trap_exit, true)` for the fail-closed boot case.

## Fixture YAMLs

`test/fixtures/pageless_rules/`:
- `default.yaml` — shipping defaults; round-trips into the canonical `%Rules{}` shape.
- `missing_caps.yaml`, `extra_caps.yaml`, `missing_policy_field.yaml`, `non_boolean_policy_field.yaml`, `write_prod_high_ungated.yaml` — capability-class validation failures.
- `missing_kubectl_class.yaml`, `extra_kubectl_class.yaml`, `bad_kubectl_verbs.yaml` — kubectl_verbs validation failures.
- `bad_function_blocklist.yaml` — function_blocklist validation failure.
- `malformed.yaml` — YAML parse failure (drives R21 fail-closed supervisor restart test).

## Test patterns

- For "key X missing/extra/wrong" cases: construct the parsed-map in-test (`Map.delete/2`, `put_in/3`) and feed `validate!/1` directly, rather than maintaining a fixture for every permutation.
- For "Agent boots successfully": `start_supervised!({Pageless.Config.Rules.Agent, path: fixture_path("default.yaml")})`.
- For "Agent crashes on invalid config": isolated `Supervisor.start_link/2` with `:one_for_one` + `Process.flag(:trap_exit, true)`; assert on the `{:error, {:shutdown, ...}}` shape rather than restarting the application supervisor.

## Discipline

- `async: true`. No global state.
- No `put_env` on application config — uses dependency injection via the `path:` opt instead.
