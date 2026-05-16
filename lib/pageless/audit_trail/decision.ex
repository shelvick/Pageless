defmodule Pageless.AuditTrail.Decision do
  @moduledoc """
  Ecto schema for one capability-gate audit decision row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @tools ~w(kubectl prometheus_query query_db mcp_runbook unknown)
  @classifications ~w(read write_dev write_prod_low write_prod_high)
  @decisions ~w(execute audit_and_execute gated approved denied executed execution_failed rejected profile_violation budget_exhausted)
  @initial_decisions ~w(execute audit_and_execute gated rejected profile_violation budget_exhausted)
  @result_statuses ~w(ok error)
  @create_required ~w(request_id alert_id agent_id tool args classification decision)a
  @fields @create_required ++
            ~w(gate_id agent_pid_inspect extracted_verb operator_ref denial_reason result_status result_summary)a

  schema "audit_trail_decisions" do
    field :request_id, :string
    field :gate_id, :string
    field :alert_id, :string
    field :agent_id, :binary_id
    field :agent_pid_inspect, :string
    field :tool, :string
    field :args, :map
    field :extracted_verb, :string
    field :classification, :string
    field :decision, :string
    field :operator_ref, :string
    field :denial_reason, :string
    field :result_status, :string
    field :result_summary, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          request_id: String.t() | nil,
          gate_id: String.t() | nil,
          alert_id: String.t() | nil,
          agent_id: Ecto.UUID.t() | nil,
          agent_pid_inspect: String.t() | nil,
          tool: String.t() | nil,
          args: map() | nil,
          extracted_verb: String.t() | nil,
          classification: String.t() | nil,
          decision: String.t() | nil,
          operator_ref: String.t() | nil,
          denial_reason: String.t() | nil,
          result_status: String.t() | nil,
          result_summary: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Builds a create/update changeset and enforces row lifecycle invariants."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = decision, attrs) do
    decision
    |> cast(attrs, @fields)
    |> validate_required(@create_required)
    |> validate_inclusion(:tool, @tools)
    |> validate_inclusion(:classification, @classifications)
    |> validate_inclusion(:decision, @decisions)
    |> validate_args_map()
    |> validate_unknown_tool()
    |> validate_transition(decision.decision)
    |> validate_decision_requirements()
    |> unique_constraint(:gate_id, name: :audit_trail_decisions_gate_id_unique_index)
  end

  defp validate_args_map(changeset) do
    case get_field(changeset, :args) do
      value when is_map(value) -> changeset
      _value -> add_error(changeset, :args, "must be a map")
    end
  end

  defp validate_unknown_tool(changeset) do
    case {get_field(changeset, :tool), get_field(changeset, :decision),
          get_field(changeset, :args)} do
      {"unknown", "profile_violation", %{"function_name" => _, "raw_args" => _}} ->
        changeset

      {"unknown", "profile_violation", _args} ->
        add_error(changeset, :args, "must include function_name and raw_args")

      {"unknown", _decision, _args} ->
        add_error(changeset, :tool, "is only valid for profile_violation")

      _known_tool ->
        changeset
    end
  end

  defp validate_transition(changeset, nil) do
    next_decision = get_field(changeset, :decision)

    if next_decision in @initial_decisions do
      changeset
    else
      add_error(changeset, :decision, "invalid initial decision")
    end
  end

  defp validate_transition(changeset, current_decision) do
    next_decision = get_field(changeset, :decision)

    if {current_decision, next_decision} in allowed_transitions() do
      changeset
    else
      add_error(changeset, :decision, "invalid transition")
    end
  end

  defp validate_decision_requirements(changeset) do
    case get_field(changeset, :decision) do
      "gated" ->
        validate_required(changeset, [:gate_id])

      "approved" ->
        validate_required(changeset, [:operator_ref])

      "denied" ->
        validate_required(changeset, [:operator_ref, :denial_reason])

      decision when decision in ["executed", "execution_failed"] ->
        changeset
        |> validate_required([:result_status, :result_summary])
        |> validate_inclusion(:result_status, @result_statuses)

      "profile_violation" ->
        validate_pregate_terminal(changeset)

      "budget_exhausted" ->
        changeset
        |> validate_pregate_terminal()
        |> validate_change(:result_summary, fn
          :result_summary, ":budget_exhausted" -> []
          :result_summary, _value -> [result_summary: "must be :budget_exhausted"]
        end)

      _decision ->
        changeset
    end
  end

  defp validate_pregate_terminal(changeset) do
    changeset
    |> validate_required([:result_status, :result_summary])
    |> validate_change(:result_status, fn
      :result_status, "error" -> []
      :result_status, _value -> [result_status: "must be error"]
    end)
    |> validate_change(:result_summary, fn
      :result_summary, value when is_binary(value) and value != "" -> []
      :result_summary, _value -> [result_summary: "can't be blank"]
    end)
    |> validate_absent(:gate_id)
    |> validate_absent(:operator_ref)
    |> validate_absent(:denial_reason)
  end

  defp validate_absent(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> add_error(changeset, field, "must be blank")
    end
  end

  defp allowed_transitions do
    [
      {"gated", "approved"},
      {"gated", "denied"},
      {"approved", "executed"},
      {"approved", "execution_failed"},
      {"execute", "executed"},
      {"execute", "execution_failed"},
      {"audit_and_execute", "executed"},
      {"audit_and_execute", "execution_failed"}
    ]
  end
end
