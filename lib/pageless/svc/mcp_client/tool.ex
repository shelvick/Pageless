defmodule Pageless.Svc.MCPClient.Tool do
  @moduledoc "Pageless-normalized MCP tool descriptor."

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map()
        }

  defstruct [:name, :description, :input_schema]
end
