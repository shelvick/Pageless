defmodule Pageless.Data.DeployLedgerTest do
  @moduledoc """
  Tests the deploy ledger table, seed contract, and demo SQL alignment.
  """

  use Pageless.DataCase, async: true

  alias Pageless.Data.DeployLedger

  describe "migration and table shape" do
    test "deploys table has the demo-critical columns and composite ordering index" do
      columns =
        Repo.query!("""
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'deploys'
        ORDER BY ordinal_position
        """)
        |> Map.fetch!(:rows)
        |> List.flatten()

      assert columns == [
               "id",
               "service",
               "version",
               "deployed_at",
               "deployed_by",
               "inserted_at",
               "updated_at"
             ]

      assert Repo.query!("""
             SELECT 1
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND tablename = 'deploys'
               AND indexdef ILIKE '%service%'
               AND indexdef ILIKE '%deployed_at%DESC%'
             """).num_rows == 1
    end
  end

  describe "seed_demo!/2" do
    test "literal B4 demo SQL returns payments-api v2.4.1 at 03:43:58 UTC by alex@" do
      DeployLedger.seed_demo!(Repo, date: ~D[2026-05-13])

      result =
        Repo.query!("""
        SELECT version, deployed_at, deployed_by
        FROM deploys
        WHERE service='payments-api'
        ORDER BY deployed_at DESC
        LIMIT 5
        """)

      assert [["v2.4.1", deployed_at, "alex@"] | _] = result.rows
      assert DateTime.to_time(deployed_at) == ~T[03:43:58.000000]
      assert deployed_at.time_zone == "Etc/UTC"
    end

    test "is idempotent for the mandatory v2.4.1 demo row" do
      DeployLedger.seed_demo!(Repo, date: ~D[2026-05-13])
      DeployLedger.seed_demo!(Repo, date: ~D[2026-05-13])

      result =
        Repo.query!(
          """
          SELECT count(*)
          FROM deploys
          WHERE service = 'payments-api'
            AND version = 'v2.4.1'
            AND deployed_by = 'alex@'
            AND deployed_at = $1
          """,
          [~U[2026-05-13 03:43:58.000000Z]]
        )

      assert [[1]] = result.rows
    end
  end

  describe "recent/3" do
    test "returns the same ordered rows as the raw B4 SQL" do
      DeployLedger.seed_demo!(Repo, date: ~D[2026-05-13])

      raw_rows =
        Repo.query!("""
        SELECT version, deployed_at, deployed_by
        FROM deploys
        WHERE service='payments-api'
        ORDER BY deployed_at DESC
        LIMIT 5
        """)
        |> Map.fetch!(:rows)

      recent_rows = DeployLedger.recent(Repo, "payments-api", 5)

      assert Enum.map(recent_rows, &[&1.version, &1.deployed_at, &1.deployed_by]) == raw_rows
    end

    test "returns an empty list when a service has no deploy rows" do
      assert DeployLedger.recent(Repo, "unknown-service", 5) == []
    end
  end
end
