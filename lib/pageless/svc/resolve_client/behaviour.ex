defmodule Pageless.Svc.ResolveClient.Behaviour do
  @moduledoc "Contract for outbound alert resolve and escalation calls."

  alias Pageless.AlertEnvelope

  @type resolve_opts :: [
          routing_key: String.t() | nil,
          req_module: module() | nil,
          metadata: map() | nil
        ]

  @type page_payload :: %{
          required(:summary) => String.t(),
          required(:severity) => :critical | :error | :warning | :info,
          optional(:dedup_key) => String.t() | nil,
          optional(:runbook_link) => String.t() | nil,
          optional(:extra) => map() | nil
        }

  @type result ::
          {:ok, %{status: pos_integer(), dedup_key: String.t() | nil}}
          | {:ok, :noop}
          | {:error, term()}

  @callback resolve(AlertEnvelope.t(), resolve_opts()) :: result()
  @callback escalate(AlertEnvelope.t(), page_payload(), resolve_opts()) :: result()
end
