defmodule Pageless.Governance.SqlSelectOnlyParser do
  @moduledoc """
  Validates SQL as a single read-only SELECT or plain EXPLAIN over SELECT.
  """

  @type validate_error ::
          :not_select
          | :multiple_statements
          | {:state_modifying_function, String.t()}
          | {:table_not_allowed, String.t()}
          | :no_rangetable
          | :parse_failure
          | :empty

  @type allowed_tables :: [String.t()] | :all
  @type opts :: [function_blocklist: [String.t()], allowed_tables: allowed_tables()]

  @hardcoded_function_blocklist_floor ~w(pg_read_file pg_read_binary_file pg_ls_dir pg_stat_file lo_export lo_import lo_get lo_put lo_from_bytea dblink_send_query dblink_get_result pg_sleep pg_logical_emit_message)

  @doc """
  Returns the security-critical function blocklist that cannot be disabled by opts.
  """
  @spec hardcoded_function_blocklist_floor() :: [String.t()]
  def hardcoded_function_blocklist_floor, do: @hardcoded_function_blocklist_floor

  @doc """
  Parses `sql` and accepts only structurally read-only SELECT statements.
  """
  @spec validate(String.t(), opts()) :: {:ok, :read} | {:error, validate_error()}
  def validate(sql, opts \\ []) when is_binary(sql) do
    sql = String.trim(sql)

    if sql == "" do
      {:error, :empty}
    else
      validate_parsed_sql(sql, opts)
    end
  end

  defp validate_parsed_sql(sql, opts) do
    with {:ok, parse_result} <- parse(sql),
         {:ok, statement} <- single_statement(parse_result),
         :ok <- read_only_statement(statement),
         :ok <- validate_function_blocklist(statement, opts),
         :ok <- validate_allowed_tables(statement, opts, sql) do
      {:ok, :read}
    end
  end

  @doc """
  Extracts relation names referenced by a read-only SELECT or plain EXPLAIN query.
  """
  @spec extract_relations(String.t()) :: {:ok, [String.t()]} | {:error, validate_error()}
  def extract_relations(sql) when is_binary(sql) do
    sql = String.trim(sql)

    if sql == "" do
      {:error, :empty}
    else
      with {:ok, parse_result} <- parse(sql),
           {:ok, statement} <- single_statement(parse_result),
           :ok <- read_only_statement(statement) do
        {:ok, statement |> collect_relations(MapSet.new(), sql) |> elem(0)}
      end
    end
  end

  defp parse(sql) do
    case PgQuery.parse(sql) do
      {:ok, parse_result} -> {:ok, parse_result}
      {:error, _reason} -> {:error, :parse_failure}
    end
  rescue
    _exception -> {:error, :parse_failure}
  catch
    _kind, _reason -> {:error, :parse_failure}
  end

  defp single_statement(%PgQuery.ParseResult{stmts: [raw_stmt]}) do
    {:ok, raw_stmt.stmt}
  end

  defp single_statement(%PgQuery.ParseResult{stmts: statements}) when length(statements) > 1 do
    {:error, :multiple_statements}
  end

  defp single_statement(_parse_result), do: {:error, :parse_failure}

  defp read_only_statement(%PgQuery.Node{node: {:select_stmt, select_stmt}}) do
    read_only_select?(select_stmt)
  end

  defp read_only_statement(%PgQuery.Node{node: {:explain_stmt, explain_stmt}}) do
    if explain_analyze?(explain_stmt.options) do
      {:error, :not_select}
    else
      read_only_statement(explain_stmt.query)
    end
  end

  defp read_only_statement(_statement), do: {:error, :not_select}

  defp read_only_select?(%PgQuery.SelectStmt{} = select_stmt) do
    if select_stmt.locking_clause == [] and is_nil(select_stmt.into_clause) and
         read_only_ctes?(select_stmt.with_clause) and no_nested_row_locks?(select_stmt) do
      :ok
    else
      {:error, :not_select}
    end
  end

  defp no_nested_row_locks?(%PgQuery.Node{node: {:select_stmt, select_stmt}}) do
    no_nested_row_locks?(select_stmt)
  end

  defp no_nested_row_locks?(%PgQuery.SelectStmt{locking_clause: locks}) when locks != [],
    do: false

  defp no_nested_row_locks?(list) when is_list(list) do
    Enum.all?(list, &no_nested_row_locks?/1)
  end

  defp no_nested_row_locks?(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> no_nested_row_locks?()
  end

  defp no_nested_row_locks?(%_struct{} = term) do
    term
    |> Map.from_struct()
    |> Map.drop([:__uf__, :locking_clause])
    |> Map.values()
    |> no_nested_row_locks?()
  end

  defp no_nested_row_locks?(map) when is_map(map) do
    map
    |> Map.drop([:__uf__, :locking_clause])
    |> Map.values()
    |> no_nested_row_locks?()
  end

  defp no_nested_row_locks?(_term), do: true

  defp read_only_ctes?(nil), do: true

  defp read_only_ctes?(%PgQuery.WithClause{ctes: ctes}) do
    Enum.all?(ctes, fn
      %PgQuery.Node{node: {:common_table_expr, cte}} -> read_only_statement(cte.ctequery) == :ok
      _other -> false
    end)
  end

  defp explain_analyze?(options) do
    Enum.any?(options, fn
      %PgQuery.Node{node: {:def_elem, %PgQuery.DefElem{defname: option}}} ->
        String.downcase(option) == "analyze"

      _other ->
        false
    end)
  end

  defp normalized_blocklist(opts) do
    opts
    |> Keyword.get(:function_blocklist, [])
    |> Kernel.++(@hardcoded_function_blocklist_floor)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp validate_function_blocklist(statement, opts) do
    statement
    |> find_blocklisted_function(normalized_blocklist(opts))
    |> validate_blocklist_result()
  end

  defp validate_blocklist_result(nil), do: :ok

  defp validate_blocklist_result(function_name),
    do: {:error, {:state_modifying_function, function_name}}

  defp validate_allowed_tables(statement, opts, sql) do
    allowed_tables = Keyword.get(opts, :allowed_tables, :all)

    if allowed_tables == :all do
      :ok
    else
      {relations, _cte_names} = collect_relations(statement, MapSet.new(), sql)

      if relations == [] do
        {:error, :no_rangetable}
      else
        normalized_allowed = allowed_tables |> Enum.map(&String.downcase/1) |> MapSet.new()

        case Enum.find(relations, fn relation ->
               not MapSet.member?(normalized_allowed, String.downcase(relation))
             end) do
          nil -> :ok
          relation -> {:error, {:table_not_allowed, relation}}
        end
      end
    end
  end

  defp find_blocklisted_function(_term, blocklist) when map_size(blocklist) == 0, do: nil

  defp find_blocklisted_function(%PgQuery.Node{node: {:func_call, func_call}}, blocklist) do
    blocklisted_name(func_call, blocklist) ||
      find_blocklisted_function(Map.from_struct(func_call), blocklist)
  end

  defp find_blocklisted_function(%PgQuery.Node{node: {_node_type, value}}, blocklist) do
    find_blocklisted_function(value, blocklist)
  end

  defp find_blocklisted_function(list, blocklist) when is_list(list) do
    Enum.find_value(list, &find_blocklisted_function(&1, blocklist))
  end

  defp find_blocklisted_function(tuple, blocklist) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> find_blocklisted_function(blocklist)
  end

  defp find_blocklisted_function(%_struct{} = term, blocklist) do
    term
    |> Map.from_struct()
    |> Map.drop([:__uf__])
    |> Map.values()
    |> find_blocklisted_function(blocklist)
  end

  defp find_blocklisted_function(map, blocklist) when is_map(map) do
    map
    |> Map.drop([:__uf__])
    |> Map.values()
    |> find_blocklisted_function(blocklist)
  end

  defp find_blocklisted_function(_term, _blocklist), do: nil

  defp blocklisted_name(%PgQuery.FuncCall{} = func_call, blocklist) do
    names = function_name_segments(func_call)
    full_name = Enum.join(names, ".")
    final_name = List.last(names)

    cond do
      MapSet.member?(blocklist, full_name) -> full_name
      MapSet.member?(blocklist, final_name) -> final_name
      true -> nil
    end
  end

  defp collect_relations(%PgQuery.Node{node: {:select_stmt, select_stmt}}, cte_names, sql) do
    collect_relations(select_stmt, cte_names, sql)
  end

  defp collect_relations(%PgQuery.Node{node: {:explain_stmt, explain_stmt}}, cte_names, sql) do
    collect_relations(explain_stmt.query, cte_names, sql)
  end

  defp collect_relations(%PgQuery.SelectStmt{} = select_stmt, cte_names, sql) do
    {cte_relations, scoped_cte_names} =
      collect_cte_relations(select_stmt.with_clause, cte_names, sql)

    {select_relations, _cte_names} =
      select_stmt
      |> Map.from_struct()
      |> Map.drop([:__uf__, :with_clause])
      |> Map.values()
      |> collect_relations(scoped_cte_names, sql)

    {dedupe_relations(cte_relations ++ select_relations), cte_names}
  end

  defp collect_relations(%PgQuery.Node{node: {:range_var, range_var}}, cte_names, sql) do
    relation = relation_name(range_var, sql)

    if MapSet.member?(cte_names, String.downcase(relation)) do
      {[], cte_names}
    else
      {[relation], cte_names}
    end
  end

  defp collect_relations(%PgQuery.Node{node: {:range_subselect, range_subselect}}, cte_names, sql) do
    collect_relations(range_subselect.subquery, cte_names, sql)
  end

  defp collect_relations(%PgQuery.Node{node: {_node_type, value}}, cte_names, sql) do
    collect_relations(value, cte_names, sql)
  end

  defp collect_relations(list, cte_names, sql) when is_list(list) do
    Enum.reduce(list, {[], cte_names}, fn item, {relations, names} ->
      {item_relations, item_names} = collect_relations(item, names, sql)
      {relations ++ item_relations, item_names}
    end)
  end

  defp collect_relations(tuple, cte_names, sql) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> collect_relations(cte_names, sql)
  end

  defp collect_relations(%_struct{} = term, cte_names, sql) do
    term
    |> Map.from_struct()
    |> Map.drop([:__uf__])
    |> Map.values()
    |> collect_relations(cte_names, sql)
  end

  defp collect_relations(map, cte_names, sql) when is_map(map) do
    map
    |> Map.drop([:__uf__])
    |> Map.values()
    |> collect_relations(cte_names, sql)
  end

  defp collect_relations(_term, cte_names, _sql), do: {[], cte_names}

  defp collect_cte_relations(nil, cte_names, _sql), do: {[], cte_names}

  defp collect_cte_relations(%PgQuery.WithClause{ctes: ctes}, cte_names, sql) do
    scoped_cte_names =
      Enum.reduce(ctes, cte_names, fn
        %PgQuery.Node{node: {:common_table_expr, %PgQuery.CommonTableExpr{ctename: name}}},
        names ->
          MapSet.put(names, String.downcase(name))

        _other, names ->
          names
      end)

    {relations, _names} = collect_relations(ctes, scoped_cte_names, sql)
    {relations, scoped_cte_names}
  end

  defp relation_name(%PgQuery.RangeVar{schemaname: schema, relname: relname} = range_var, sql)
       when schema in [nil, ""] do
    source_relation_name(range_var, sql) || relname
  end

  defp relation_name(%PgQuery.RangeVar{schemaname: schema, relname: relname}, _sql) do
    schema <> "." <> relname
  end

  defp source_relation_name(%PgQuery.RangeVar{location: location}, sql)
       when is_integer(location) and location >= 0 do
    sql
    |> binary_part(location, byte_size(sql) - location)
    |> String.split(~r/\s|,|\)|;/, parts: 2)
    |> hd()
  end

  defp source_relation_name(_range_var, _sql), do: nil

  defp dedupe_relations(relations) do
    relations
    |> Enum.reduce({[], MapSet.new()}, fn relation, {acc, seen} ->
      if MapSet.member?(seen, relation) do
        {acc, seen}
      else
        {[relation | acc], MapSet.put(seen, relation)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp function_name_segments(%PgQuery.FuncCall{funcname: funcname}) do
    Enum.flat_map(funcname, fn
      %PgQuery.Node{node: {:string, %PgQuery.String{sval: value}}} -> [String.downcase(value)]
      _other -> []
    end)
  end
end
