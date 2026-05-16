defmodule Pageless.Proc.Remediator.Prompt do
  @moduledoc "Builds Gemini prompt and tool configuration for the remediator agent."

  alias Pageless.AlertEnvelope
  alias Pageless.Proc.Remediator.Proposal

  @doc "Builds Gemini generation options for remediator proposal selection."
  @spec gemini_opts(AlertEnvelope.t(), [map()]) :: keyword()
  def gemini_opts(envelope, findings) do
    [
      model: :pro,
      temperature: 0.0,
      tool_choice: {:specific, "propose_action"},
      prompt: inspect(%{envelope: envelope_summary(envelope), findings: findings}),
      system_instruction: system_instruction(),
      tools: [Proposal.tool_definition()]
    ]
  end

  @doc "Summarizes an alert envelope for prompt context."
  @spec envelope_summary(AlertEnvelope.t()) :: map()
  def envelope_summary(envelope) do
    %{
      alert_id: envelope.alert_id,
      source: envelope.source,
      severity: envelope.severity,
      alert_class: envelope.alert_class,
      title: envelope.title,
      service: envelope.service,
      fingerprint: envelope.fingerprint,
      started_at: envelope.started_at,
      labels: envelope.labels
    }
  end

  @doc "Summarizes investigator findings for remediator state rows."
  @spec findings_summary([map()]) :: map()
  def findings_summary(findings) do
    %{
      count: length(findings),
      hypothesis: findings |> List.first() |> hypothesis()
    }
  end

  @doc "Returns a compact evidence link for a findings collection."
  @spec findings_link([map()]) :: String.t() | nil
  def findings_link([]), do: nil
  def findings_link(findings), do: "agent_state:findings:#{length(findings)}"

  @spec system_instruction() :: String.t()
  defp system_instruction do
    """
    You are an incident remediator. You receive an alert and structured investigator findings,
    and you propose ONE concrete kubectl action to remediate.

    Reasoning protocol (FOLLOW EXACTLY):
      1. Identify the cheapest reversible action that could plausibly remediate
         (e.g., kubectl rollout restart). Add it to considered_alternatives with
         a one-sentence reason it MIGHT work.
      2. Critique that action against the findings -- does it address the root cause?
         If the findings indicate the deployed code itself is bad, restart loops
         back into the same broken code. Add the rejection reason to that
         considered_alternatives entry.
      3. Propose the action that DOES address the root cause (e.g., kubectl
         rollout undo). This is your final proposal.

    You MUST emit exactly one function call to propose_action with at least
    one entry in considered_alternatives. The propose_action.args field must
    be a complete kubectl argv array starting with the verb (no leading "kubectl").
    """
  end

  @spec hypothesis(map() | nil) :: String.t() | nil
  defp hypothesis(%{} = finding),
    do: Map.get(finding, :hypothesis) || Map.get(finding, "hypothesis")

  defp hypothesis(_finding), do: nil
end
