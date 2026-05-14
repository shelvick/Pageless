// Pageless dashboard client bundle.
//
// Boots Phoenix.LiveView's LiveSocket so the operator dashboard can receive
// real-time alert + conductor events broadcast on the server side.

import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { LiveFlowHook } from "live_flow";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { LiveFlow: LiveFlowHook },
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

// Expose for debugging in IEx/browser console.
window.liveSocket = liveSocket;
