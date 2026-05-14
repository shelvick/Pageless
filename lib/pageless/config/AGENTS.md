# lib/pageless/config/

Rules loader for `priv/pageless.yaml`. Pure-data struct + Agent wrapper.

## Modules

- `Pageless.Config.Rules` (`rules.ex`): struct + `load!/1` + `validate!/1` + `policy_for/2`.
- `Pageless.Config.Rules.Agent` (in `rules/`): supervised wrapper that holds the loaded struct.

## Rules struct

`@enforce_keys [:capability_classes, :kubectl_verbs, :function_blocklist]`. Plus `investigator_profiles` (default `%{}`) and `alert_class_routing` (default `%{}`).

- `capability_classes :: %{atom => %{auto: bool, audit: bool, gated: bool}}` for the four classes `:read`, `:write_dev`, `:write_prod_low`, `:write_prod_high`.
- `kubectl_verbs :: %{atom => [String.t()]}` keyed by the same four classes.
- `function_blocklist :: [String.t()]`.

## Atomization rule (safety)

Only the fixed class names and policy-field names are atomized — via compile-time `@class_atoms` and `@policy_field_atoms` lookup maps. Never `String.to_existing_atom/1` against arbitrary YAML input. Optional `investigator_profiles` / `alert_class_routing` maps are preserved with string keys.

## Validation (`validate!/1`) — fail loudly on every violation

- All three required top-level keys present.
- `capability_classes`: exactly the four allowed class keys; each value has exactly `auto/audit/gated` booleans.
- **Semantic check:** `write_prod_high.gated` MUST be `true`. Misconfiguration raises `ArgumentError` naming the offending class.
- `kubectl_verbs`: exactly the four allowed class keys; each value a list of strings.
- `function_blocklist`: list of strings (may be empty).
- `investigator_profiles` / `alert_class_routing`: accepted as maps (if absent, default `%{}`).

## Public API

- `load!(path) :: Rules.t()` — reads file, parses YAML, validates. Raises on any failure.
- `validate!(parsed_map) :: Rules.t()` — runs validation pipeline against an already-parsed map.
- `policy_for(rules, class) :: capability_policy()` — pure lookup; raises `KeyError` only on hand-built invalid struct.

## Failure modes (fail-closed boot)

| Condition | Raises |
|---|---|
| File missing | `File.Error` |
| YAML parse failure | `YamlElixir.ParsingError` |
| Required key missing / extra / wrong shape | `ArgumentError` (names the offender) |
| `write_prod_high` ungated | `ArgumentError` |

## Dependencies

- `yaml_elixir`.
- Consumed by `Pageless.Governance.{CapabilityGate, VerbTableClassifier, SqlSelectOnlyParser}` (struct passed explicitly) and (future) `Pageless.Triager` for routing.
