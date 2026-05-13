defmodule Pageless.DemoConductor do
  @moduledoc """
  Demo stagecraft driver.

  Will broadcast B1/B2/B7/B8 conductor events on PubSub and expose
  `beat_mode/1` returning `:conductor | :real` per beat — the single source of
  truth for the drift-prevention layers (yellow `[CONDUCTOR]` badges in the
  dashboard, `mix demo.check` block-on-fake gate) described in PAGELESS.md.

  Empty stub for now; populated as the Conductor Change Set lands. See
  `noderr/specs/CON_DemoConductor.md` (to be drafted) and
  `noderr/specs/CON_BeatModeRegistry.md`.
  """
end
