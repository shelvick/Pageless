defmodule PagelessWeb.Plugs.PagerDutyHMACVerify do
  @moduledoc """
  Verifies PagerDuty Webhooks v3 HMAC signatures against the raw body.
  """

  import Plug.Conn

  @behaviour Plug

  @type secret_provider :: (-> binary() | nil)
  @type init_opts :: [
          secret: binary() | nil,
          secret_provider: secret_provider(),
          required: boolean(),
          header_name: String.t()
        ]
  @type compiled_opts :: %{
          secret: binary() | nil,
          secret_provider: secret_provider(),
          required: boolean(),
          header_name: String.t()
        }

  @doc "Compiles HMAC verification options."
  @impl true
  @spec init(init_opts()) :: compiled_opts()
  def init(opts) do
    %{
      secret: Keyword.get(opts, :secret),
      secret_provider:
        Keyword.get(opts, :secret_provider, fn ->
          Application.get_env(:pageless, :pagerduty_webhook_secret)
        end),
      required:
        Keyword.get_lazy(opts, :required, fn ->
          Application.get_env(:pageless, :pagerduty_webhook_required, true)
        end),
      header_name: Keyword.get(opts, :header_name, "x-pagerduty-signature")
    }
  end

  @doc "Passes valid requests through and rejects unverifiable requests with 401."
  @impl true
  @spec call(Plug.Conn.t(), compiled_opts()) :: Plug.Conn.t()
  def call(conn, %{secret: init_secret, secret_provider: provider} = opts) do
    secret = init_secret || provider.()
    do_call(conn, secret, opts.required, opts.header_name)
  end

  defp do_call(conn, nil, false, _header_name), do: conn

  defp do_call(conn, nil, true, _header_name), do: reject(conn, "missing_secret")

  defp do_call(conn, secret, _required, header_name) when is_binary(secret) do
    case verify(conn.assigns[:raw_body], header(conn, header_name), secret) do
      :ok -> conn
      {:error, reason} -> reject(conn, reason)
    end
  end

  defp verify(nil, _signature_header, _secret), do: {:error, "missing_raw_body"}
  defp verify(_body, nil, _secret), do: {:error, "missing_signature_header"}
  defp verify(_body, "", _secret), do: {:error, "empty_signature_header"}

  defp verify(body, signature_header, secret) do
    computed = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    if signature_header
       |> parse_v1_entries()
       |> Enum.any?(&Plug.Crypto.secure_compare(&1, computed)) do
      :ok
    else
      {:error, "signature_mismatch"}
    end
  end

  defp parse_v1_entries(signature_header) do
    signature_header
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn
      "v1=" <> hex -> [String.downcase(hex)]
      _entry -> []
    end)
  end

  defp header(conn, header_name) do
    conn
    |> get_req_header(header_name)
    |> List.first()
  end

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{error: "hmac_verification_failed", reason: reason})
    )
    |> halt()
  end
end
