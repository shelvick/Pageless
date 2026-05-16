defmodule PagelessWeb.Router do
  @moduledoc """
  Top-level router.

  Day 1: only `GET /` for the scaffold smoke test. The operator dashboard live
  route + webhook POST routes land in later Change Sets.
  """
  use Phoenix.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Plug.Conn

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :webhooks_public do
    plug(PagelessWeb.Plugs.WebhookRateLimit, route_id: :webhook_alertmanager)
    plug(PagelessWeb.Plugs.InjectPubSub)
  end

  pipeline :webhooks_signed do
    plug(PagelessWeb.Plugs.WebhookRateLimit, route_id: :webhook_pagerduty)
    plug(PagelessWeb.Plugs.PagerDutyHMACVerify)
    plug(PagelessWeb.Plugs.InjectPubSub)
  end

  pipeline :demo do
    plug(PagelessWeb.Plugs.WebhookRateLimit, route_id: :webhook_fire_test_alert)
    plug(:accepts, ["json"])
  end

  scope "/", PagelessWeb do
    pipe_through(:browser)

    live_session :default, root_layout: {PagelessWeb.Layouts, :root} do
      live("/", OperatorDashboardLive, :index)
    end
  end

  scope "/webhook", PagelessWeb do
    pipe_through(:webhooks_public)

    post("/alertmanager", AlertmanagerWebhookController, :create)
  end

  scope "/webhook", PagelessWeb do
    pipe_through(:webhooks_signed)

    post("/pagerduty-events-v2", PagerDutyWebhookController, :create)
  end

  scope "/demo", PagelessWeb do
    pipe_through(:demo)

    post("/fire-test-alert", FireTestAlertController, :create)
  end
end
