defmodule Pageless.Proc.Investigator.Gemini do
  @moduledoc "Gemini prompt, option, and finding parsing helpers for investigator agents."

  alias Pageless.AlertEnvelope
  alias Pageless.Proc.Investigator.Profile

  @doc "Builds Gemini streaming options for an investigator turn."
  @spec opts(String.t() | nil, [map()], String.t(), String.t(), atom()) :: keyword()
  def opts(prompt, tools, alert_id, agent_id, profile_name) do
    [
      model: :pro,
      temperature: 0.0,
      tool_choice: :auto,
      prompt: prompt,
      tools: tools,
      caller: self(),
      metadata: %{alert_id: alert_id, agent_id: agent_id, profile: profile_name}
    ]
  end

  @doc "Renders the profile-specific investigation prompt for an alert envelope."
  @spec render_prompt(Profile.t(), AlertEnvelope.t()) :: String.t()
  def render_prompt(profile, envelope) do
    assigns = [
      alert_id: envelope.alert_id,
      service: envelope.service,
      title: envelope.title,
      severity: envelope.severity,
      labels: envelope.labels,
      annotations: envelope.annotations
    ]

    EEx.eval_string(profile.prompt_template, assigns: assigns)
  end

  @doc "Decodes Gemini's final text into known investigator finding keys."
  @spec decode_findings(String.t()) :: {:ok, map()} | :error
  def decode_findings(text) do
    with {:ok, decoded} <- Jason.decode(text),
         true <- is_map(decoded) do
      {:ok, atomize_known_keys(decoded)}
    else
      _other -> :error
    end
  end

  @spec atomize_known_keys(map()) :: map()
  defp atomize_known_keys(map) do
    Map.new(map, fn
      {"hypothesis", value} -> {:hypothesis, value}
      {"confidence", value} -> {:confidence, value}
      {"evidence", value} -> {:evidence, value}
      {key, value} -> {key, value}
    end)
  end
end
