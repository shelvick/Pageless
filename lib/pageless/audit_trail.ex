defmodule Pageless.AuditTrail do
  @moduledoc """
  Persistence API for capability-gate audit decisions.
  """

  @behaviour Pageless.AuditTrail.Behaviour

  import Ecto.Query

  alias Pageless.AuditTrail.Decision
  alias Pageless.Repo

  @doc "Records the initial audit decision row for a classified tool call."
  @spec record_decision(map()) :: {:ok, Decision.t()} | {:error, Ecto.Changeset.t()}
  def record_decision(attrs) do
    %Decision{}
    |> Decision.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches the audit decision row associated with a gate id."
  @spec get_by_gate_id(String.t()) :: Decision.t() | nil
  def get_by_gate_id(gate_id), do: Repo.get_by(Decision, gate_id: gate_id)

  @doc "Updates a decision row while enforcing allowed lifecycle transitions."
  @spec update_decision(Decision.t(), map()) :: {:ok, Decision.t()} | {:error, Ecto.Changeset.t()}
  def update_decision(%Decision{} = decision, attrs) do
    decision
    |> Decision.changeset(attrs)
    |> Repo.update()
  end

  @doc "Atomically claims a pending gate as approved."
  @spec claim_gate_for_approval(String.t(), String.t()) ::
          {:ok, Decision.t()} | {:error, :no_pending_gate | Ecto.Changeset.t()}
  def claim_gate_for_approval(gate_id, operator_ref) do
    claim_gate(gate_id, %{decision: "approved", operator_ref: operator_ref})
  end

  @doc "Atomically claims a pending gate as denied."
  @spec claim_gate_for_denial(String.t(), String.t(), String.t()) ::
          {:ok, Decision.t()} | {:error, :no_pending_gate | Ecto.Changeset.t()}
  def claim_gate_for_denial(gate_id, operator_ref, reason) do
    claim_gate(gate_id, %{decision: "denied", operator_ref: operator_ref, denial_reason: reason})
  end

  defp claim_gate(gate_id, attrs) do
    Repo.transaction(fn ->
      query =
        from decision in Decision,
          where: decision.gate_id == ^gate_id and decision.decision == "gated",
          lock: "FOR UPDATE"

      case Repo.one(query) do
        nil -> Repo.rollback(:no_pending_gate)
        decision -> update_claimed_decision(decision, attrs)
      end
    end)
    |> case do
      {:ok, decision} -> {:ok, decision}
      {:error, :no_pending_gate} -> {:error, :no_pending_gate}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp update_claimed_decision(decision, attrs) do
    case update_decision(decision, attrs) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
