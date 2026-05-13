defmodule Pageless.Repo do
  @moduledoc """
  Ecto repository.

  Holds the audit trail (capability-gate decisions, operator approvals) and
  the deploy ledger queried by the deploys-investigator during B4 of the demo
  script. Tests use the SQL sandbox with `Sandbox.start_owner!` per global
  CLAUDE.md test-isolation rules; spawned agent processes that need DB access
  receive `sandbox_owner` and call `Sandbox.allow/3` in `handle_continue/2`
  (not `init/1` — race condition).
  """
  use Ecto.Repo, otp_app: :pageless, adapter: Ecto.Adapters.Postgres
end
