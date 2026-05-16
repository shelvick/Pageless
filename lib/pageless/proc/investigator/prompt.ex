defmodule Pageless.Proc.Investigator.Prompt do
  @moduledoc "Builds investigator prompts and Gemini request options."

  @doc "Builds Gemini stream options for the current investigator turn."
  @spec gemini_opts(map()) :: keyword()
  def gemini_opts(state) do
    [
      model: :pro,
      temperature: 0.0,
      tool_choice: :auto,
      prompt: state.prompt,
      tools: state.tools,
      caller: self(),
      metadata: %{alert_id: state.alert_id, agent_id: state.agent_id, profile: state.profile.name}
    ]
  end

  @doc "Renders the profile prompt template with alert-envelope fields."
  @spec render(map()) :: String.t()
  def render(state) do
    assigns = [
      alert_id: state.envelope.alert_id,
      service: state.envelope.service,
      title: state.envelope.title,
      severity: state.envelope.severity,
      labels: state.envelope.labels,
      annotations: state.envelope.annotations
    ]

    EEx.eval_string(state.profile.prompt_template, assigns: assigns)
  end

  @doc "Appends a tool result to the prompt for the next Gemini turn."
  @spec continue(map(), atom(), term()) :: map()
  def continue(state, tool, result) do
    prompt =
      [state.prompt, "\nTool ", Atom.to_string(tool), " result: ", inspect(result)]
      |> IO.iodata_to_binary()

    %{state | prompt: prompt, current_text: ""}
  end
end
