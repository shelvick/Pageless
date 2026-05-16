defmodule Pageless.Tools.QueryDB do
  @moduledoc "PostgreSQL-backed read-only SQL wrapper for query_db tool calls."

  @behaviour Pageless.Tools.QueryDB.Behaviour

  alias Pageless.Governance.SqlSelectOnlyParser
  alias Pageless.Governance.ToolCall
  alias Pageless.Tools.QueryDB.Behaviour

  @default_statement_timeout_ms 1_500
  @default_max_rows 1_000

  @doc "Executes a query_db tool call with application defaults."
  @impl true
  @spec query(ToolCall.t()) :: {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  def query(%ToolCall{tool: :query_db} = call) do
    query(call, Application.get_env(:pageless, :query_db, []))
  end

  @doc "Executes a query_db tool call with explicit options."
  @impl true
  @spec query(ToolCall.t(), Behaviour.exec_opts()) ::
          {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  def query(%ToolCall{tool: :query_db, args: sql}, opts) do
    with {:ok, trimmed_sql} <- validate_args(sql),
         :ok <- validate_sql(trimmed_sql, opts) do
      execute(trimmed_sql, opts)
    else
      {:error, :invalid_args} -> {:error, base_error(:invalid_args, sql, 0)}
      {:error, {:sql_blocked, reason}} -> {:error, base_error({:sql_blocked, reason}, sql)}
    end
  end

  @doc "Returns the Gemini function declaration for read-only SQL queries."
  @impl true
  @spec function_call_definition() :: map()
  def function_call_definition do
    %{
      "name" => "query_db",
      "description" => "Run a capability-gated, SELECT-only SQL query.",
      "parameters" => %{
        "type" => "object",
        "required" => ["sql"],
        "properties" => %{"sql" => %{"type" => "string"}}
      }
    }
  end

  defp validate_args(sql) when is_binary(sql) do
    case String.trim(sql) do
      "" -> {:error, :invalid_args}
      trimmed_sql -> {:ok, trimmed_sql}
    end
  end

  defp validate_args(_sql), do: {:error, :invalid_args}

  defp validate_sql(sql, opts) do
    case SqlSelectOnlyParser.validate(sql,
           function_blocklist: Keyword.get(opts, :function_blocklist, []),
           allowed_tables: Keyword.get(opts, :allowed_tables, :all)
         ) do
      {:ok, :read} -> :ok
      {:error, reason} -> {:error, {:sql_blocked, reason}}
    end
  end

  defp execute(sql, opts) do
    repo = Keyword.get(opts, :repo, Pageless.Repo)

    statement_timeout_ms =
      positive_integer_opt(opts, :statement_timeout_ms, @default_statement_timeout_ms)

    max_rows = positive_integer_opt(opts, :max_rows, @default_max_rows)
    start_ms = System.monotonic_time(:millisecond)

    case repo.transaction(fn -> run_query(repo, sql, statement_timeout_ms, max_rows) end,
           timeout: statement_timeout_ms + 1_000
         ) do
      {:ok, result} -> {:ok, ok_result(result, sql, max_rows, start_ms)}
      {:error, {:query_error, error}} -> {:error, query_error(error, sql, start_ms)}
      {:error, error} -> {:error, query_error(error, sql, start_ms)}
    end
  end

  defp run_query(repo, sql, statement_timeout_ms, max_rows) do
    repo.query!("SET LOCAL transaction_read_only = on", [])
    repo.query!("SET LOCAL statement_timeout = '#{statement_timeout_ms}ms'", [])

    case repo.query(wrapped_sql(sql), [max_rows + 1]) do
      {:ok, result} -> result
      {:error, error} -> repo.rollback({:query_error, error})
    end
  end

  defp wrapped_sql(sql) do
    inner_sql =
      sql |> String.trim_trailing() |> String.trim_trailing(";") |> String.trim_trailing()

    "SELECT * FROM (\n#{inner_sql}\n) AS _pageless_outer_wrap LIMIT $1"
  end

  defp ok_result(%{rows: rows, columns: columns, num_rows: num_rows}, sql, max_rows, start_ms) do
    truncated = num_rows > max_rows
    rows = Enum.take(rows, max_rows)

    %{
      rows: rows,
      columns: columns,
      num_rows: length(rows),
      truncated: truncated,
      duration_ms: duration_since(start_ms),
      command: sql
    }
  end

  defp query_error(%Postgrex.Error{postgres: %{code: :query_canceled}} = error, sql, start_ms) do
    base_error(:statement_timeout, sql, duration_since(start_ms), message(error))
  end

  defp query_error(%Postgrex.Error{} = error, sql, start_ms) do
    base_error(:query_failed, sql, duration_since(start_ms), Exception.message(error))
  end

  defp query_error(%DBConnection.ConnectionError{} = error, sql, start_ms) do
    base_error(:query_failed, sql, duration_since(start_ms), error.message)
  end

  defp query_error(error, sql, start_ms) do
    base_error(:query_failed, sql, duration_since(start_ms), Exception.message(error))
  rescue
    Protocol.UndefinedError ->
      base_error(:query_failed, sql, duration_since(start_ms), inspect(error))
  end

  defp base_error(reason, command, duration_ms \\ 0, message \\ nil) do
    %{
      rows: nil,
      columns: nil,
      num_rows: nil,
      truncated: false,
      duration_ms: duration_ms,
      command: command,
      reason: reason,
      message: message
    }
  end

  defp positive_integer_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp message(%Postgrex.Error{postgres: %{message: message}}) when is_binary(message),
    do: message

  defp message(error), do: Exception.message(error)

  defp duration_since(start_ms), do: max(System.monotonic_time(:millisecond) - start_ms, 0)
end
