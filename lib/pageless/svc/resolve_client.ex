defmodule Pageless.Svc.ResolveClient do
  @moduledoc "PagerDuty Events v2 client for resolving alerts and sending page-outs."

  @behaviour Pageless.Svc.ResolveClient.Behaviour

  alias Pageless.AlertEnvelope
  alias Pageless.Svc.ResolveClient.Behaviour

  @pd_endpoint "https://events.pagerduty.com/v2/enqueue"

  @doc "Resolves a PagerDuty alert or no-ops for non-PagerDuty sources."
  @impl Behaviour
  @spec resolve(AlertEnvelope.t(), Behaviour.resolve_opts()) :: Behaviour.result()
  def resolve(envelope, opts \\ []), do: do_resolve(envelope, opts)

  @doc "Triggers a PagerDuty page-out or no-ops for non-PagerDuty sources."
  @impl Behaviour
  @spec escalate(AlertEnvelope.t(), Behaviour.page_payload(), Behaviour.resolve_opts()) ::
          Behaviour.result()
  def escalate(envelope, page, opts \\ []), do: do_escalate(envelope, page, opts)

  @spec do_resolve(AlertEnvelope.t(), Behaviour.resolve_opts()) :: Behaviour.result()
  defp do_resolve(%AlertEnvelope{source: :pagerduty} = envelope, opts) do
    body = %{
      "routing_key" => routing_key(opts),
      "event_action" => "resolve",
      "dedup_key" => envelope.source_ref || envelope.alert_id
    }

    post_pd(:resolve, envelope, body, opts)
  end

  defp do_resolve(%AlertEnvelope{source: source}, _opts) when source in [:alertmanager, :demo],
    do: {:ok, :noop}

  @spec do_escalate(AlertEnvelope.t(), Behaviour.page_payload(), Behaviour.resolve_opts()) ::
          Behaviour.result()
  defp do_escalate(%AlertEnvelope{source: :pagerduty} = envelope, page, opts) do
    body = %{
      "routing_key" => routing_key(opts),
      "event_action" => "trigger",
      "dedup_key" => page[:dedup_key] || envelope.alert_id,
      "payload" => %{
        "summary" => page.summary,
        "severity" => page.severity |> to_string(),
        "source" => "pageless",
        "component" => envelope.service,
        "custom_details" => custom_details(envelope, page)
      }
    }

    body
    |> maybe_put_links(page[:runbook_link])
    |> then(&post_pd(:escalate, envelope, &1, opts))
  end

  defp do_escalate(%AlertEnvelope{source: source}, _page, _opts)
       when source in [:alertmanager, :demo],
       do: {:ok, :noop}

  @spec post_pd(:resolve | :escalate, AlertEnvelope.t(), map(), keyword()) :: Behaviour.result()
  defp post_pd(action, envelope, %{"routing_key" => nil}, opts) do
    emit(action, envelope, opts, :missing_routing_key, 0)
    {:error, :missing_routing_key}
  end

  defp post_pd(action, envelope, body, opts) do
    start_time = System.monotonic_time()
    req_module = Keyword.get(opts, :req_module, Req)

    result =
      case req_module.post(@pd_endpoint,
             json: body,
             receive_timeout: 5_000,
             retry: false,
             caller: opts[:caller],
             response: opts[:response]
           ) do
        {:ok, %{status: 202}} -> {:ok, %{status: 202, dedup_key: body["dedup_key"]}}
        {:ok, %{status: 400, body: response_body}} -> {:error, {:pd_bad_request, response_body}}
        {:ok, %{status: 429}} -> {:error, :rate_limited}
        {:ok, %{status: status}} when status >= 500 -> {:error, {:pd_unavailable, status}}
        {:error, reason} -> {:error, {:network, reason}}
      end

    emit(action, envelope, opts, status_or_reason(result), duration_us(start_time))
    result
  end

  @spec routing_key(keyword()) :: String.t() | nil
  defp routing_key(opts) do
    Keyword.get(opts, :routing_key) || Application.get_env(:pageless, :pagerduty_routing_key) ||
      System.get_env("PAGERDUTY_ROUTING_KEY")
  end

  @spec custom_details(AlertEnvelope.t(), map()) :: map()
  defp custom_details(envelope, page) do
    %{
      "alert_id" => envelope.alert_id,
      "alert_class" => to_string(envelope.alert_class)
    }
    |> Map.merge(page[:extra] || %{})
  end

  @spec maybe_put_links(map(), String.t() | nil) :: map()
  defp maybe_put_links(body, nil), do: body

  defp maybe_put_links(body, link),
    do: Map.put(body, "links", [%{"href" => link, "text" => "Runbook"}])

  @spec emit(:resolve | :escalate, AlertEnvelope.t(), keyword(), term(), non_neg_integer()) :: :ok
  defp emit(action, envelope, opts, status_or_reason, duration_us) do
    :telemetry.execute(
      [:pageless, :resolve_client, :pd, action],
      %{duration_us: duration_us},
      %{
        source: envelope.source,
        alert_id: envelope.alert_id,
        status_or_reason: status_or_reason,
        metadata: Keyword.get(opts, :metadata)
      }
    )
  end

  @spec duration_us(integer()) :: non_neg_integer()
  defp duration_us(start_time) do
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :microsecond)
  end

  @spec status_or_reason(Behaviour.result()) :: term()
  defp status_or_reason({:ok, %{status: status}}), do: status
  defp status_or_reason({:error, reason}), do: reason
end
