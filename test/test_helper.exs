ExUnit.start()

# Start only essential dependencies, NOT full application
# Avoids global singleton GenServers that cause DB ownership issues
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)

# Start Repo
{:ok, _} =
  case Pageless.Repo.start_link() do
    {:ok, pid} -> {:ok, pid}
    {:error, {:already_started, pid}} -> {:ok, pid}
  end

# Configure sandbox for concurrent testing
Ecto.Adapters.SQL.Sandbox.mode(Pageless.Repo, :manual)
