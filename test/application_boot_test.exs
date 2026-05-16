defmodule Pageless.ApplicationBootTest do
  @moduledoc "Tests application supervision of fail-closed rules loading."

  use ExUnit.Case, async: true

  alias Pageless.Config.Rules
  alias Pageless.Config.Rules.Agent, as: RulesAgent

  defp fixture_path(name) do
    Path.expand("fixtures/pageless_rules/#{name}", __DIR__)
  end

  test "Application supervisor starts the rules Agent" do
    [{_, rules_agent, _, _}] =
      Pageless.Supervisor
      |> Supervisor.which_children()
      |> Enum.filter(fn {id, _, _, _} -> id == RulesAgent end)

    assert RulesAgent.get(rules_agent).__struct__ == Rules
  end

  test "Application supervisor starts webhook guard singletons" do
    children = Supervisor.which_children(Pageless.Supervisor)

    assert {_id, rate_limiter, _type, _modules} =
             Enum.find(children, fn
               {Pageless.RateLimiter, _pid, _type, _modules} -> true
               _child -> false
             end)

    assert {_id, webhook_dedup, _type, _modules} =
             Enum.find(children, fn
               {Pageless.WebhookDedup, _pid, _type, _modules} -> true
               _child -> false
             end)

    assert {_id, gemini_budget, _type, _modules} =
             Enum.find(children, fn
               {Pageless.GeminiBudget, _pid, _type, _modules} -> true
               _child -> false
             end)

    assert is_pid(rate_limiter)
    assert is_pid(webhook_dedup)
    assert is_pid(gemini_budget)
  end

  test "rules child fails closed under supervisor when configured path is malformed" do
    Process.flag(:trap_exit, true)

    assert {:error,
            {:shutdown,
             {:failed_to_start_child, RulesAgent, {:EXIT, {%YamlElixir.ParsingError{}, _stack}}}}} =
             Supervisor.start_link([{RulesAgent, path: fixture_path("malformed.yaml")}],
               strategy: :one_for_one
             )
  end
end
