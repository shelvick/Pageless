defmodule Pageless.Proc.Remediator.Proposal do
  @moduledoc """
  Builds and normalizes remediator proposal payloads from Gemini function calls,
  plus the gated kubectl `ToolCall` envelope and the Gemini function declaration.
  """

  alias Pageless.Governance.ToolCall

  @valid_actions ~w(rollout_undo rollout_restart scale_down delete apply exec other)a
  @valid_classes ~w(read write_dev write_prod_low write_prod_high)a

  @type t :: %{
          action: atom(),
          args: [String.t()],
          classification_hint: atom(),
          rationale: String.t(),
          considered_alternatives: [map()],
          request_id: String.t()
        }

  @doc "Builds a normalized proposal map from Gemini function-call args."
  @spec build(map()) :: {:ok, t()} | {:error, atom()}
  def build(args) when is_map(args) do
    with {:ok, argv} <- argv_arg(args),
         {:ok, alternatives} <- alternatives_arg(args) do
      {:ok,
       %{
         action: action_atom(get_arg(args, "action", :action)),
         args: argv,
         classification_hint:
           class_atom(get_arg(args, "classification_hint", :classification_hint)),
         rationale: non_empty(get_arg(args, "rationale", :rationale), "No rationale provided."),
         considered_alternatives: alternatives,
         request_id: request_id()
       }}
    end
  end

  def build(_args), do: {:error, :invalid_proposal}

  @doc "Returns the public payload shape for proposal events."
  @spec payload(t()) :: map()
  def payload(proposal) do
    %{
      action: proposal.action,
      args: proposal.args,
      classification_hint: proposal.classification_hint,
      rationale: proposal.rationale,
      considered_alternatives: proposal.considered_alternatives
    }
  end

  @doc "Builds the gated kubectl tool-call envelope for a proposal."
  @spec tool_call(t(), String.t(), String.t(), [map()]) :: ToolCall.t()
  def tool_call(proposal, alert_id, agent_pid_inspect, findings) do
    %ToolCall{
      tool: :kubectl,
      args: proposal.args,
      agent_id: Ecto.UUID.generate(),
      agent_pid_inspect: agent_pid_inspect,
      alert_id: alert_id,
      request_id: proposal.request_id,
      reasoning_context: %{
        summary: proposal.rationale,
        evidence_link: findings_link(findings)
      }
    }
  end

  @doc "Returns the Gemini function declaration for remediator proposals."
  @spec tool_definition() :: map()
  def tool_definition do
    %{
      function_declarations: [
        %{
          name: "propose_action",
          parameters: %{
            type: "object",
            required: [
              "action",
              "args",
              "classification_hint",
              "rationale",
              "considered_alternatives"
            ],
            properties: %{
              action: %{type: "string"},
              args: %{type: "array", items: %{type: "string"}, minItems: 1},
              classification_hint: %{
                type: "string",
                enum: Enum.map(@valid_classes, &Atom.to_string/1)
              },
              rationale: %{type: "string"},
              considered_alternatives: %{
                type: "array",
                minItems: 1,
                items: %{
                  type: "object",
                  required: ["action", "reason_rejected"],
                  properties: %{
                    action: %{type: "string"},
                    reason_rejected: %{type: "string"}
                  }
                }
              }
            }
          }
        }
      ]
    }
  end

  @spec argv_arg(map()) :: {:ok, [String.t()]} | {:error, :invalid_args}
  defp argv_arg(args) do
    case get_arg(args, "args", :args) do
      argv when is_list(argv) ->
        if Enum.all?(argv, &is_binary/1) and argv != [] do
          {:ok, argv}
        else
          {:error, :invalid_args}
        end

      _other ->
        {:error, :invalid_args}
    end
  end

  @spec alternatives_arg(map()) :: {:ok, [map()]} | {:error, :invalid_considered_alternatives}
  defp alternatives_arg(args) do
    alternatives = get_arg(args, "considered_alternatives", :considered_alternatives)

    if is_list(alternatives) and alternatives != [] and
         Enum.all?(alternatives, &valid_alternative?/1) do
      {:ok, alternatives}
    else
      {:error, :invalid_considered_alternatives}
    end
  end

  @spec valid_alternative?(term()) :: boolean()
  defp valid_alternative?(%{} = alternative) do
    is_binary(get_arg(alternative, "action", :action)) and
      is_binary(get_arg(alternative, "reason_rejected", :reason_rejected))
  end

  defp valid_alternative?(_alternative), do: false

  @spec action_atom(term()) :: atom()
  defp action_atom(value) when is_atom(value) and value in @valid_actions, do: value

  defp action_atom(value) when is_binary(value) do
    Enum.find(@valid_actions, :other, &(Atom.to_string(&1) == value))
  end

  defp action_atom(_value), do: :other

  @spec class_atom(term()) :: atom()
  defp class_atom(value) when is_atom(value) and value in @valid_classes, do: value

  defp class_atom(value) when is_binary(value) do
    Enum.find(@valid_classes, :write_prod_high, &(Atom.to_string(&1) == value))
  end

  defp class_atom(_value), do: :write_prod_high

  @spec get_arg(map(), String.t(), atom()) :: term()
  defp get_arg(args, string_key, atom_key) do
    Map.get(args, string_key) || Map.get(args, atom_key)
  end

  @spec findings_link([map()]) :: String.t() | nil
  defp findings_link([]), do: nil
  defp findings_link(findings), do: "agent_state:findings:#{length(findings)}"

  @spec non_empty(term(), String.t()) :: String.t()
  defp non_empty(value, fallback) when value in [nil, ""], do: fallback
  defp non_empty(value, _fallback) when is_binary(value), do: value
  defp non_empty(_value, fallback), do: fallback

  @spec request_id() :: String.t()
  defp request_id do
    "rem_req_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
