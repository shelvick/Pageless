defmodule PagelessWeb.ErrorHTML do
  @moduledoc """
  Minimal HTML error renderer for endpoint-generated errors.
  """

  @doc "Renders a plain HTML error body for any status template."
  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  @doc false
  @spec __phoenix_template_render__(String.t(), String.t(), map(), keyword()) :: String.t()
  def __phoenix_template_render__(template, "html", assigns, _caller) do
    render(template, assigns)
  end
end
