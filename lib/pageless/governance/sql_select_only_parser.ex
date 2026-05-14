defmodule Pageless.Governance.SqlSelectOnlyParser do
  @moduledoc """
  Validates SQL as a single read-only SELECT or plain EXPLAIN over SELECT.
  """

  @type validate_error ::
          :not_select
          | :multiple_statements
          | {:state_modifying_function, String.t()}
          | :parse_failure
          | :empty

  @type opts :: [function_blocklist: [String.t()]]

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
         :ok <- read_only_statement(statement) do
      statement
      |> find_blocklisted_function(normalized_blocklist(opts))
      |> validate_blocklist_result()
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
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp validate_blocklist_result(nil), do: {:ok, :read}

  defp validate_blocklist_result(function_name),
    do: {:error, {:state_modifying_function, function_name}}

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

  defp function_name_segments(%PgQuery.FuncCall{funcname: funcname}) do
    Enum.flat_map(funcname, fn
      %PgQuery.Node{node: {:string, %PgQuery.String{sval: value}}} -> [String.downcase(value)]
      _other -> []
    end)
  end
end
