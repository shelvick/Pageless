defmodule Pageless.Svc.GeminiClient.Chunk do
  @moduledoc "Stream chunk forwarded to agent mailboxes by the Gemini client adapter."

  alias Pageless.Svc.GeminiClient.FunctionCall

  @type chunk_type :: :text | :function_call

  @type t :: %__MODULE__{
          type: chunk_type(),
          text: String.t() | nil,
          function_call: FunctionCall.t() | nil,
          ref: reference()
        }

  defstruct [:type, :text, :function_call, :ref]
end
