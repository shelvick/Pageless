defmodule Pageless.MixProject do
  @moduledoc """
  Mix project definition for Pageless.

  Declares deps, build configuration, and the OTP application entry point
  (`Pageless.Application`). Edited Day 1 hour 1 to add the Phoenix/Ecto/Req
  stack required for the on-call agent build per `noderr/planning/day1-hour1.md`.
  """
  use Mix.Project

  def project do
    [
      app: :pageless,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  def application do
    [
      mod: {Pageless.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix stack
      {:phoenix, "~> 1.7"},
      {:bandit, "~> 1.5"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_live_dashboard, "~> 0.8"},

      # Data
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},

      # HTTP + JSON + YAML + JSON Schema
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_json_schema, "~> 0.10"},
      {:gemini_ex, "~> 0.13.0"},

      # Agent-tree viz
      {:live_flow, "~> 0.2.3"},

      # SQL structural parser (GATE_SQLSelectOnlyParser)
      {:pg_query_ex, "~> 0.5"},

      # MCP client (Day 4) — deferred
      # {:anubis_mcp, ...}

      # Dev reload + asset pipeline
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},

      # Dev/test tooling
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:hammox, "~> 0.7", only: :test},
      {:req_cassette, "~> 0.4", only: :test}
    ]
  end
end
