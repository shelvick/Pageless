defmodule Pageless.Repo.Migrations.CreateDeploys do
  @moduledoc false

  use Ecto.Migration

  @doc false
  def change do
    create table(:deploys) do
      add :service, :text, null: false
      add :version, :text, null: false
      add :deployed_at, :timestamptz, null: false
      add :deployed_by, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:deploys, [:service, "deployed_at DESC"])

    create unique_index(:deploys, [:service, :version, :deployed_by, :deployed_at],
             name: :deploys_demo_identity_index
           )
  end
end
