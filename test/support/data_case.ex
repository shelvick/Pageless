defmodule Pageless.DataCase do
  @moduledoc """
  Test helper for data-layer tests.

  Starts one SQL sandbox owner per test so data tests can stay async and still
  share ownership explicitly with spawned processes when needed.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Pageless.DataCase, only: [errors_on: 1]

      alias Pageless.Repo
    end
  end

  setup tags do
    sandbox_owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Pageless.Repo, shared: not tags[:async])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner)
    end)

    {:ok, sandbox_owner: sandbox_owner}
  end

  @doc """
  Converts changeset errors into a field-keyed map for assertions.
  """
  @spec errors_on(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
