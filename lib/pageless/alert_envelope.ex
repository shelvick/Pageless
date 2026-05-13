defmodule Pageless.AlertEnvelope do
  @moduledoc """
  Canonical normalized alert data passed from webhook intake to downstream workers.
  """

  @derive Jason.Encoder
  @enforce_keys [
    :alert_id,
    :source,
    :source_ref,
    :fingerprint,
    :received_at,
    :status,
    :severity,
    :alert_class,
    :title,
    :payload_raw
  ]

  defstruct [
    :alert_id,
    :source,
    :source_ref,
    :fingerprint,
    :received_at,
    :started_at,
    :status,
    :severity,
    :alert_class,
    :title,
    :service,
    :payload_raw,
    labels: %{},
    annotations: %{}
  ]

  @type source :: :alertmanager | :pagerduty | :demo
  @type status :: atom()
  @type severity :: atom()
  @type alert_class :: atom()

  @type t :: %__MODULE__{
          alert_id: String.t(),
          source: source(),
          source_ref: String.t(),
          fingerprint: String.t(),
          received_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          status: status(),
          severity: severity(),
          alert_class: alert_class(),
          title: String.t(),
          service: String.t() | nil,
          labels: %{String.t() => term()},
          annotations: %{String.t() => term()},
          payload_raw: map()
        }

  @required_fields [
    :alert_id,
    :source,
    :source_ref,
    :fingerprint,
    :received_at,
    :status,
    :severity,
    :alert_class,
    :title,
    :payload_raw
  ]

  @doc "Builds a validated alert envelope from normalized attributes."
  @spec new(map()) :: {:ok, t()} | {:error, {:missing_field, atom()}}
  def new(attrs) when is_map(attrs) do
    case Enum.find(@required_fields, &(not Map.has_key?(attrs, &1))) do
      nil -> {:ok, struct!(__MODULE__, attrs)}
      field -> {:error, {:missing_field, field}}
    end
  end
end
