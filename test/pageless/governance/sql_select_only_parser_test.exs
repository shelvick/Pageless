defmodule Pageless.Governance.SqlSelectOnlyParserTest do
  @moduledoc "Tests Packet 2 SQL SELECT-only parser behavior."

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pageless.Governance.SqlSelectOnlyParser

  describe "validate/2 accepts read-only SQL" do
    test "accepts simple SELECT" do
      assert SqlSelectOnlyParser.validate("SELECT * FROM deploys") == {:ok, :read}
    end

    test "accepts lowercase select keyword" do
      sql = "select version, deployed_at from deploys order by deployed_at desc limit 5"

      assert SqlSelectOnlyParser.validate(sql) == {:ok, :read}
    end

    test "accepts S2 DB-load investigator query" do
      sql =
        "SELECT count(*), state, wait_event_type FROM pg_stat_activity " <>
          "WHERE application_name LIKE 'payments-api%' GROUP BY state, wait_event_type"

      assert SqlSelectOnlyParser.validate(sql) == {:ok, :read}
    end

    test "accepts CTE-prefixed SELECT" do
      sql =
        "WITH recent AS (SELECT * FROM deploys ORDER BY id DESC LIMIT 10) SELECT * FROM recent"

      assert SqlSelectOnlyParser.validate(sql) == {:ok, :read}
    end

    test "accepts S3 pool-state investigator query" do
      sql =
        "SELECT pid, state, wait_event, query_start FROM pg_stat_activity WHERE state = 'idle in transaction'"

      assert SqlSelectOnlyParser.validate(sql) == {:ok, :read}
    end

    test "accepts plain EXPLAIN" do
      assert SqlSelectOnlyParser.validate("EXPLAIN SELECT * FROM deploys") == {:ok, :read}
    end

    test "accepts SELECT calling non-blocklisted functions" do
      sql = "SELECT now() - xact_start AS age FROM pg_stat_activity LIMIT 10"

      assert SqlSelectOnlyParser.validate(sql) == {:ok, :read}
    end

    test "ignores DROP keyword inside SQL comment" do
      assert SqlSelectOnlyParser.validate("SELECT --DROP TABLE deploys\n * FROM deploys") ==
               {:ok, :read}
    end

    test "ignores DROP keyword inside string literal" do
      assert SqlSelectOnlyParser.validate("SELECT 'DROP TABLE deploys' FROM deploys") ==
               {:ok, :read}
    end
  end

  describe "validate/2 rejects non-SELECT statements" do
    test "rejects INSERT" do
      assert SqlSelectOnlyParser.validate("INSERT INTO foo VALUES (1)") == {:error, :not_select}
    end

    test "rejects UPDATE" do
      assert SqlSelectOnlyParser.validate("UPDATE deploys SET x=1") == {:error, :not_select}
    end

    test "rejects DELETE" do
      assert SqlSelectOnlyParser.validate("DELETE FROM deploys") == {:error, :not_select}
    end

    test "rejects DROP TABLE" do
      assert SqlSelectOnlyParser.validate("DROP TABLE deploys") == {:error, :not_select}
    end

    test "rejects ALTER TABLE" do
      assert SqlSelectOnlyParser.validate("ALTER TABLE deploys ADD COLUMN x INT") ==
               {:error, :not_select}
    end

    test "rejects ALTER USER (S2 narrative)" do
      assert SqlSelectOnlyParser.validate("ALTER USER api_user CONNECTION LIMIT 200") ==
               {:error, :not_select}
    end

    test "rejects TRUNCATE" do
      assert SqlSelectOnlyParser.validate("TRUNCATE TABLE deploys") == {:error, :not_select}
    end

    test "rejects GRANT" do
      assert SqlSelectOnlyParser.validate("GRANT SELECT ON foo TO bar") == {:error, :not_select}
    end

    test "rejects EXPLAIN ANALYZE" do
      for sql <- [
            "EXPLAIN ANALYZE SELECT * FROM deploys",
            "EXPLAIN (ANALYZE) SELECT * FROM deploys",
            "EXPLAIN (ANALYZE true) SELECT * FROM deploys"
          ] do
        assert SqlSelectOnlyParser.validate(sql) == {:error, :not_select}
      end
    end

    test "rejects VACUUM" do
      assert SqlSelectOnlyParser.validate("VACUUM deploys") == {:error, :not_select}
    end

    test "rejects SET" do
      assert SqlSelectOnlyParser.validate("SET statement_timeout = '5s'") == {:error, :not_select}
    end

    test "rejects additional forbidden statement classes" do
      for sql <- [
            "REVOKE SELECT ON deploys FROM app_user",
            "CREATE TABLE deploys_archive (id int)",
            "COPY deploys TO STDOUT",
            "BEGIN",
            "COMMIT",
            "ROLLBACK"
          ] do
        assert SqlSelectOnlyParser.validate(sql) == {:error, :not_select}
      end
    end

    test "rejects data-modifying CTE bodies" do
      statements = [
        "WITH deleted AS (DELETE FROM deploys RETURNING *) SELECT * FROM deleted",
        "WITH inserted AS (INSERT INTO deploys(id) VALUES (1) RETURNING *) SELECT * FROM inserted",
        "WITH updated AS (UPDATE deploys SET version = 'v2' RETURNING *) SELECT * FROM updated",
        "WITH merged AS (MERGE INTO deploys d USING incoming i ON d.id = i.id WHEN MATCHED THEN UPDATE SET version = i.version RETURNING *) SELECT * FROM merged"
      ]

      for sql <- statements do
        assert SqlSelectOnlyParser.validate(sql) == {:error, :not_select}
      end
    end

    test "rejects SELECT FOR UPDATE row locks" do
      assert SqlSelectOnlyParser.validate("SELECT * FROM deploys FOR UPDATE") ==
               {:error, :not_select}
    end

    test "rejects SELECT FOR SHARE row locks" do
      assert SqlSelectOnlyParser.validate("SELECT * FROM deploys FOR SHARE") ==
               {:error, :not_select}
    end

    test "rejects all row-locking SELECT variants" do
      for lock_clause <- ["FOR NO KEY UPDATE", "FOR KEY SHARE"] do
        assert SqlSelectOnlyParser.validate("SELECT * FROM deploys #{lock_clause}") ==
                 {:error, :not_select}
      end
    end

    test "rejects SELECT INTO table creation" do
      assert SqlSelectOnlyParser.validate("SELECT * INTO deploys_copy FROM deploys") ==
               {:error, :not_select}
    end

    test "rejects nested row-locking SELECTs" do
      sql = "SELECT * FROM (SELECT * FROM deploys FOR UPDATE) locked_deploys"

      assert SqlSelectOnlyParser.validate(sql) == {:error, :not_select}
    end

    test "rejects plain EXPLAIN over non-SELECT statements" do
      assert SqlSelectOnlyParser.validate("EXPLAIN UPDATE deploys SET x=1") ==
               {:error, :not_select}
    end

    property "any non-SELECT statement type rejects as :not_select" do
      statements = [
        "INSERT INTO t VALUES (1)",
        "UPDATE t SET x=1",
        "DELETE FROM t",
        "DROP TABLE t",
        "ALTER TABLE t ADD COLUMN x INT",
        "CREATE TABLE t (id int)",
        "COPY t TO STDOUT",
        "REVOKE SELECT ON t FROM app_user",
        "TRUNCATE t",
        "VACUUM t",
        "SET statement_timeout = '5s'",
        "BEGIN",
        "COMMIT",
        "ROLLBACK"
      ]

      check all(stmt <- StreamData.member_of(statements), max_runs: 30) do
        assert SqlSelectOnlyParser.validate(stmt) == {:error, :not_select}
      end
    end
  end

  describe "validate/2 rejects statement chaining" do
    test "rejects SELECT followed by DELETE in one input" do
      assert SqlSelectOnlyParser.validate("SELECT * FROM deploys; DELETE FROM deploys") ==
               {:error, :multiple_statements}
    end

    test "rejects two SELECT statements as multiple_statements" do
      assert SqlSelectOnlyParser.validate("SELECT 1; SELECT 2") == {:error, :multiple_statements}
    end
  end

  describe "validate/2 applies the function blocklist" do
    test "rejects SELECT calling pg_terminate_backend (S3 beat)" do
      sql =
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle in transaction'"

      assert SqlSelectOnlyParser.validate(sql, function_blocklist: ["pg_terminate_backend"]) ==
               {:error, {:state_modifying_function, "pg_terminate_backend"}}
    end

    test "rejects SELECT calling pg_cancel_backend" do
      sql = "SELECT pg_cancel_backend(pid) FROM pg_stat_activity LIMIT 1"

      assert SqlSelectOnlyParser.validate(sql, function_blocklist: ["pg_cancel_backend"]) ==
               {:error, {:state_modifying_function, "pg_cancel_backend"}}
    end

    test "rejects SELECT calling pg_advisory_lock" do
      assert SqlSelectOnlyParser.validate(
               "SELECT pg_advisory_lock(1)",
               function_blocklist: ["pg_advisory_lock"]
             ) == {:error, {:state_modifying_function, "pg_advisory_lock"}}
    end

    test "finds blocklisted function in WHERE clause" do
      sql = "SELECT * FROM deploys WHERE id = pg_terminate_backend(123)"

      assert SqlSelectOnlyParser.validate(sql, function_blocklist: ["pg_terminate_backend"]) ==
               {:error, {:state_modifying_function, "pg_terminate_backend"}}
    end

    test "honors custom function_blocklist opt" do
      sql = "SELECT custom_dangerous_fn() FROM foo"

      assert SqlSelectOnlyParser.validate(sql, function_blocklist: ["custom_dangerous_fn"]) ==
               {:error, {:state_modifying_function, "custom_dangerous_fn"}}
    end

    test "matches schema-qualified blocklisted function by final segment" do
      sql = "SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_stat_activity"

      assert SqlSelectOnlyParser.validate(sql, function_blocklist: ["pg_terminate_backend"]) ==
               {:error, {:state_modifying_function, "pg_terminate_backend"}}
    end

    test "matches blocklisted function case-insensitively" do
      sql = "SELECT PG_TERMINATE_BACKEND(pid) FROM pg_stat_activity"

      assert SqlSelectOnlyParser.validate(sql, function_blocklist: ["pg_terminate_backend"]) ==
               {:error, {:state_modifying_function, "pg_terminate_backend"}}
    end
  end

  describe "validate/2 handles invalid input" do
    test "returns :empty for empty string" do
      assert SqlSelectOnlyParser.validate("") == {:error, :empty}
    end

    test "returns :empty for whitespace-only string" do
      assert SqlSelectOnlyParser.validate("   \n\t  ") == {:error, :empty}
    end

    test "returns :parse_failure for unparseable input" do
      assert SqlSelectOnlyParser.validate("not valid sql at all !@#") == {:error, :parse_failure}
    end
  end
end
