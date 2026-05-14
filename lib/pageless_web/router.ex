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

  pipeline :webhooks do
    plug(:accepts, ["json"])
    plug(PagelessWeb.Plugs.InjectPubSub)
  end

  pipeline :demo do
    plug(:accepts, ["json"])
  end

  scope "/", PagelessWeb do
    pipe_through(:browser)

    live_session :default, root_layout: {PagelessWeb.Layouts, :root} do
      live("/", OperatorDashboardLive, :index)
    end
  end

  scope "/webhook", PagelessWeb do
    pipe_through(:webhooks)

    post("/alertmanager", AlertmanagerWebhookController, :create)
    post("/pagerduty-events-v2", PagerDutyWebhookController, :create)
  end

  scope "/demo", PagelessWeb do
    pipe_through(:demo)

    post("/fire-test-alert", FireTestAlertController, :create)
  end
end
