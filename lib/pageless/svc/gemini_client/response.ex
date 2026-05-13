defmodule Pageless.Svc.GeminiClient.Response do
  @moduledoc "Normalized non-streaming Gemini response returned to Pageless agents."

  alias Pageless.Svc.GeminiClient.FunctionCall

  @type finish_reason :: :stop | :max_tokens | :safety | :recitation | :tool_calls | :other

  @type usage :: %{
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          text: String.t(),
          function_calls: [FunctionCall.t()],
          finish_reason: finish_reason(),
          usage: usage() | nil,
          raw: map()
        }

  defstruct text: "", function_calls: [], finish_reason: :other, usage: nil, raw: %{}
end
