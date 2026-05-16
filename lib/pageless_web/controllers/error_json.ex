defmodule PagelessWeb.ErrorJSON do
  @moduledoc """
  Minimal JSON error renderer for endpoint-generated errors.
  """

  @doc "Renders a JSON error body for any status template."
  @spec render(String.t(), map()) :: map()
  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end

  @doc false
  @spec __phoenix_template_render__(String.t(), String.t(), map(), keyword()) :: map()
  def __phoenix_template_render__(template, "json", assigns, _caller) do
    render(template, assigns)
  end
end
