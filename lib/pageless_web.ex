defmodule PagelessWeb do
  @moduledoc """
  Web layer namespace.

  The endpoint, router, controllers, and (later) LiveViews live under this
  namespace. Right now Day 1 only ships a plain controller serving 200 OK at
  `/`; the operator dashboard LiveView (`UI_OperatorDashboard` per
  `noderr/noderr_tracker.md`) lands in a later Change Set.
  """

  @doc "Static asset prefixes served directly by `Plug.Static` from `priv/static`."
  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)
end
