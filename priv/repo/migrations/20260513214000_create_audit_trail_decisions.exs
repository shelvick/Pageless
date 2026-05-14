defmodule Pageless.Repo.Migrations.CreateAuditTrailDecisions do
  use Ecto.Migration

  def change do
    create table(:audit_trail_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :request_id, :string, null: false
      add :gate_id, :string
      add :alert_id, :string, null: false
      add :agent_id, :binary_id, null: false
      add :agent_pid_inspect, :string
      add :tool, :string, null: false
      add :args, :map, null: false
      add :extracted_verb, :string
      add :classification, :string, null: false
      add :decision, :string, null: false
      add :operator_ref, :string
      add :denial_reason, :string
      add :result_status, :string
      add :result_summary, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:audit_trail_decisions, [:request_id])
    create unique_index(:audit_trail_decisions, [:gate_id], where: "gate_id IS NOT NULL", name: :audit_trail_decisions_gate_id_unique_index)
    create index(:audit_trail_decisions, [:alert_id])
    create index(:audit_trail_decisions, [:agent_id])
    create index(:audit_trail_decisions, [:inserted_at])
    create index(:audit_trail_decisions, [:decision])
  end
end
