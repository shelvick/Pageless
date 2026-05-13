defmodule PagelessWeb do
  @moduledoc """
  Web layer namespace.

  The endpoint, router, controllers, and LiveViews live under this namespace.
  The root route serves the operator dashboard LiveView.
  """

  @doc "Static asset prefixes served directly by `Plug.Static` from `priv/static`."
  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)
end
