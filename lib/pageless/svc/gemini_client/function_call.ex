defmodule Pageless.Svc.GeminiClient.FunctionCall do
  @moduledoc "Function-call descriptor emitted by Gemini."

  @type t :: %__MODULE__{
          name: String.t(),
          args: map(),
          id: String.t() | nil
        }

  defstruct [:name, :args, :id]
end
