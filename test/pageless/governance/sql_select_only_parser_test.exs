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

  describe "extract_relations/1" do
    test "extracts a single FROM relation" do
      assert SqlSelectOnlyParser.extract_relations("SELECT * FROM deploys") == {:ok, ["deploys"]}
    end

    test "preserves schema qualification" do
      assert SqlSelectOnlyParser.extract_relations("SELECT * FROM public.deploys") ==
               {:ok, ["public.deploys"]}
    end

    test "finds both sides of a JOIN" do
      sql = "SELECT * FROM deploys d JOIN services s ON d.service_id = s.id"

      assert SqlSelectOnlyParser.extract_relations(sql) == {:ok, ["deploys", "services"]}
    end

    test "walks into FROM subqueries" do
      sql = "SELECT * FROM (SELECT id FROM deploys) AS sub"

      assert SqlSelectOnlyParser.extract_relations(sql) == {:ok, ["deploys"]}
    end

    test "returns base tables inside CTEs but not CTE aliases" do
      sql = "WITH recent AS (SELECT * FROM deploys) SELECT * FROM recent"

      assert SqlSelectOnlyParser.extract_relations(sql) == {:ok, ["deploys"]}
    end

    test "transitively resolves CTE-to-CTE references" do
      sql = "WITH a AS (SELECT * FROM deploys), b AS (SELECT * FROM a) SELECT * FROM b"

      assert SqlSelectOnlyParser.extract_relations(sql) == {:ok, ["deploys"]}
    end

    test "deduplicates repeated relations" do
      sql = "SELECT * FROM deploys d1 JOIN deploys d2 ON d1.id < d2.id"

      assert SqlSelectOnlyParser.extract_relations(sql) == {:ok, ["deploys"]}
    end

    test "walks lateral subquery relations" do
      sql =
        "SELECT * FROM deploys d JOIN LATERAL (SELECT * FROM services s WHERE s.id = d.service_id) svc ON true"

      assert SqlSelectOnlyParser.extract_relations(sql) == {:ok, ["deploys", "services"]}
    end

    test "returns empty list for SELECT with no FROM" do
      assert SqlSelectOnlyParser.extract_relations("SELECT 1") == {:ok, []}
    end

    test "preserves relation-name case" do
      assert SqlSelectOnlyParser.extract_relations("SELECT * FROM Deploys") == {:ok, ["Deploys"]}
    end

    test "returns binary relation names" do
      assert {:ok, relations} = SqlSelectOnlyParser.extract_relations("SELECT * FROM deploys")
      assert Enum.all?(relations, &is_binary/1)
    end

    test "returns :parse_failure on parse error" do
      assert SqlSelectOnlyParser.extract_relations("not valid sql") == {:error, :parse_failure}
    end

    test "rejects non-SELECT statements" do
      assert SqlSelectOnlyParser.extract_relations("DELETE FROM deploys") == {:error, :not_select}
    end

    test "does not apply function blocklist" do
      assert SqlSelectOnlyParser.extract_relations("SELECT pg_sleep(1) FROM deploys") ==
               {:ok, ["deploys"]}
    end
  end

  describe "validate/2 applies allowed_tables" do
    test "accepts allowed relations and enforces changed allowlist" do
      assert SqlSelectOnlyParser.validate("SELECT * FROM deploys", allowed_tables: ["deploys"]) ==
               {:ok, :read}

      assert SqlSelectOnlyParser.validate("SELECT * FROM deploys", allowed_tables: ["services"]) ==
               {:error, {:table_not_allowed, "deploys"}}
    end

    test "rejects relations outside the allowlist" do
      assert SqlSelectOnlyParser.validate(
               "SELECT * FROM audit_trail_decisions",
               allowed_tables: ["deploys"]
             ) == {:error, {:table_not_allowed, "audit_trail_decisions"}}
    end

    test "accepts any relation by default while keeping hardcoded floor" do
      assert SqlSelectOnlyParser.validate("SELECT * FROM any_table", function_blocklist: []) ==
               {:ok, :read}

      assert SqlSelectOnlyParser.validate("SELECT pg_sleep(1) FROM any_table",
               function_blocklist: []
             ) ==
               {:error, {:state_modifying_function, "pg_sleep"}}
    end

    test "matches case-insensitively" do
      assert SqlSelectOnlyParser.validate("SELECT * FROM Deploys", allowed_tables: ["deploys"]) ==
               {:ok, :read}
    end

    test "rejects CTE-laundered access to disallowed table" do
      sql = "WITH legal AS (SELECT * FROM forbidden_table) SELECT * FROM legal"

      assert SqlSelectOnlyParser.validate(sql, allowed_tables: ["legal"]) ==
               {:error, {:table_not_allowed, "forbidden_table"}}
    end

    test "rejects subquery-laundered access" do
      sql = "SELECT * FROM (SELECT * FROM forbidden_table) AS sub"

      assert SqlSelectOnlyParser.validate(sql, allowed_tables: ["sub"]) ==
               {:error, {:table_not_allowed, "forbidden_table"}}
    end

    test "rejects nested EXISTS subquery access" do
      sql = "SELECT EXISTS(SELECT 1 FROM forbidden_table)"

      assert SqlSelectOnlyParser.validate(sql, allowed_tables: ["deploys"]) ==
               {:error, {:table_not_allowed, "forbidden_table"}}
    end

    test "enforces strict schema-qualified matching" do
      assert SqlSelectOnlyParser.validate("SELECT * FROM public.deploys",
               allowed_tables: ["deploys"]
             ) ==
               {:error, {:table_not_allowed, "public.deploys"}}
    end
  end

  describe ":no_rangetable rejection" do
    test "rejects relation-free SELECTs when allowed_tables is restricted" do
      cases = [
        {"SELECT 1", ["deploys"]},
        {"SELECT generate_series(1, 10)", ["deploys"]},
        {"SELECT now()", ["deploys"]},
        {"WITH x AS (SELECT 1) SELECT * FROM x", ["x"]}
      ]

      for {sql, allowed_tables} <- cases do
        assert SqlSelectOnlyParser.validate(sql, allowed_tables: allowed_tables) ==
                 {:error, :no_rangetable}
      end
    end

    test "preserves unrestricted :all behavior for relation-free SELECTs" do
      for sql <- [
            "SELECT 1",
            "SELECT generate_series(1, 10)",
            "SELECT now()",
            "WITH x AS (SELECT 1) SELECT * FROM x"
          ] do
        assert SqlSelectOnlyParser.validate(sql, allowed_tables: :all) == {:ok, :read}
      end
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

    test "rejects pg_read_file via hardcoded floor without yaml entries" do
      assert SqlSelectOnlyParser.validate("SELECT pg_read_file('/etc/passwd')") ==
               {:error, {:state_modifying_function, "pg_read_file"}}
    end

    test "rejects every function in the hardcoded floor with no yaml entries" do
      assert SqlSelectOnlyParser.hardcoded_function_blocklist_floor() == [
               "pg_read_file",
               "pg_read_binary_file",
               "pg_ls_dir",
               "pg_stat_file",
               "lo_export",
               "lo_import",
               "lo_get",
               "lo_put",
               "lo_from_bytea",
               "dblink_send_query",
               "dblink_get_result",
               "pg_sleep",
               "pg_logical_emit_message"
             ]

      for function_name <- SqlSelectOnlyParser.hardcoded_function_blocklist_floor() do
        sql = "SELECT #{function_name}()"

        assert SqlSelectOnlyParser.validate(sql) ==
                 {:error, {:state_modifying_function, function_name}}
      end
    end

    test "hardcoded floor is not suppressible by empty function_blocklist opt" do
      assert SqlSelectOnlyParser.validate("SELECT pg_sleep(10)", function_blocklist: []) ==
               {:error, {:state_modifying_function, "pg_sleep"}}
    end

    test "hardcoded floor matches schema-qualified function names" do
      assert SqlSelectOnlyParser.validate("SELECT pg_catalog.pg_read_file('/etc/passwd')") ==
               {:error, {:state_modifying_function, "pg_read_file"}}
    end

    test "effective blocklist is union of floor and yaml" do
      assert SqlSelectOnlyParser.validate("SELECT custom_fn()", function_blocklist: ["custom_fn"]) ==
               {:error, {:state_modifying_function, "custom_fn"}}

      assert SqlSelectOnlyParser.validate("SELECT pg_sleep(10)",
               function_blocklist: ["custom_fn"]
             ) ==
               {:error, {:state_modifying_function, "pg_sleep"}}
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
