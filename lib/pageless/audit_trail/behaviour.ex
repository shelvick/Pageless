defmodule Pageless.AuditTrail.Behaviour do
  @moduledoc """
  Behaviour for audit-trail persistence used by the capability gate.
  """

  alias Pageless.AuditTrail.Decision

  @doc "Persists an initial capability-gate decision row."
  @callback record_decision(map()) :: {:ok, Decision.t()} | {:error, term()}

  @doc "Fetches an audit decision row by its gate id."
  @callback get_by_gate_id(String.t()) :: Decision.t() | nil

  @doc "Updates an existing decision row with the next state or result."
  @callback update_decision(Decision.t(), map()) :: {:ok, Decision.t()} | {:error, term()}

  @doc "Atomically claims a pending gate for approval."
  @callback claim_gate_for_approval(String.t(), String.t()) ::
              {:ok, Decision.t()} | {:error, :no_pending_gate | term()}

  @doc "Atomically claims a pending gate for denial."
  @callback claim_gate_for_denial(String.t(), String.t(), String.t()) ::
              {:ok, Decision.t()} | {:error, :no_pending_gate | term()}
end
