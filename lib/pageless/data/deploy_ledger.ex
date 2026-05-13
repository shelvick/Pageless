defmodule Pageless.Data.DeployLedger do
  @moduledoc """
  Ecto schema and query helpers for deploy rows used by the deploy investigator.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  @type t :: %__MODULE__{
          id: integer() | nil,
          service: String.t() | nil,
          version: String.t() | nil,
          deployed_at: DateTime.t() | nil,
          deployed_by: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "deploys" do
    field :service, :string
    field :version, :string
    field :deployed_at, :utc_datetime_usec
    field :deployed_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Inserts the mandatory demo deploy row if it is not already present.
  """
  @spec seed_demo!(Ecto.Repo.t(), keyword()) :: t()
  def seed_demo!(repo, opts \\ []) do
    deployed_at = demo_deployed_at(Keyword.get(opts, :date, Date.utc_today()))

    attrs = %{
      service: "payments-api",
      version: "v2.4.1",
      deployed_at: deployed_at,
      deployed_by: "alex@"
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:service, :version, :deployed_by, :deployed_at]
    )
  end

  @doc """
  Returns recent deploys for a service in newest-first order.
  """
  @spec recent(Ecto.Repo.t(), String.t(), pos_integer()) :: [t()]
  def recent(repo, service, limit \\ 5) do
    __MODULE__
    |> where([deploy], deploy.service == ^service)
    |> order_by([deploy], desc: deploy.deployed_at)
    |> limit(^limit)
    |> repo.all()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  defp changeset(deploy, attrs) do
    deploy
    |> cast(attrs, [:service, :version, :deployed_at, :deployed_by])
    |> validate_required([:service, :version, :deployed_at, :deployed_by])
  end

  @spec demo_deployed_at(Date.t()) :: DateTime.t()
  defp demo_deployed_at(date) do
    {:ok, naive_datetime} = NaiveDateTime.new(date, ~T[03:43:58.000000])
    DateTime.from_naive!(naive_datetime, "Etc/UTC")
  end
end
