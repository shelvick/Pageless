defmodule Pageless.Svc.MCPClient.ToolResult do
  @moduledoc "Pageless-normalized MCP tool-call result."

  @type content_block ::
          %{type: :text, text: String.t()}
          | %{type: :image, data: binary(), mime_type: String.t() | nil}
          | %{type: :resource, resource: map()}
          | %{type: :unknown, raw: map()}

  @type t :: %__MODULE__{
          content: [content_block()],
          is_error: boolean(),
          raw: map()
        }

  defstruct content: [], is_error: false, raw: %{}
end
