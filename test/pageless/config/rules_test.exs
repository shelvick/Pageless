defmodule Pageless.Config.RulesTest do
  @moduledoc "Tests Packet 1 rules YAML loading and validation behavior."

  use ExUnit.Case, async: true

  alias Pageless.Config.Rules
  alias Pageless.Config.Rules.Agent, as: RulesAgent

  @classes ~w(read write_dev write_prod_low write_prod_high)a

  defp fixture_path(name) do
    Path.expand("../../fixtures/pageless_rules/#{name}", __DIR__)
  end

  defp valid_rules_map(overrides \\ %{}) do
    Map.merge(
      %{
        "capability_classes" => %{
          "read" => %{"auto" => true, "audit" => false, "gated" => false},
          "write_dev" => %{"auto" => true, "audit" => true, "gated" => false},
          "write_prod_low" => %{"auto" => true, "audit" => true, "gated" => false},
          "write_prod_high" => %{"auto" => false, "audit" => true, "gated" => true}
        },
        "kubectl_verbs" => %{
          "read" => ["get", "logs", "describe", "events", "top"],
          "write_dev" => [],
          "write_prod_low" => ["rollout restart", "scale-up"],
          "write_prod_high" => ["rollout undo", "delete", "scale-down", "scale", "apply", "exec"]
        },
        "function_blocklist" => ["pg_terminate_backend", "pg_cancel_backend"]
      },
      overrides
    )
  end

  describe "load!/1" do
    test "parses the default pageless.yaml fixture into a valid %Rules{}" do
      rules = Rules.load!(fixture_path("default.yaml"))

      assert rules.__struct__ == Rules
      assert map_size(rules.capability_classes) == 4
      assert map_size(rules.kubectl_verbs) == 4
      assert is_list(rules.function_blocklist)
    end

    test "produces capability_classes with all four classes and correct booleans" do
      rules = Rules.load!(fixture_path("default.yaml"))

      assert Map.keys(rules.capability_classes) |> Enum.sort() ==
               [:read, :write_dev, :write_prod_high, :write_prod_low]

      assert rules.capability_classes.read == %{auto: true, audit: false, gated: false}
      assert rules.capability_classes.write_dev == %{auto: true, audit: true, gated: false}
      assert rules.capability_classes.write_prod_low == %{auto: true, audit: true, gated: false}
      assert rules.capability_classes.write_prod_high == %{auto: false, audit: true, gated: true}
    end

    test "produces kubectl_verbs map with rollout undo in write_prod_high" do
      rules = Rules.load!(fixture_path("default.yaml"))

      assert Map.keys(rules.kubectl_verbs) |> Enum.sort() ==
               [:read, :write_dev, :write_prod_high, :write_prod_low]

      assert Enum.all?(rules.kubectl_verbs, fn {_class, verbs} ->
               is_list(verbs) and Enum.all?(verbs, &is_binary/1)
             end)

      assert "rollout undo" in rules.kubectl_verbs.write_prod_high
    end

    test "includes pg_terminate_backend in function_blocklist" do
      rules = Rules.load!(fixture_path("default.yaml"))

      assert Enum.all?(rules.function_blocklist, &is_binary/1)
      assert "pg_terminate_backend" in rules.function_blocklist
    end

    test "raises File.Error when path does not exist" do
      assert_raise File.Error, fn ->
        Rules.load!(fixture_path("missing.yaml"))
      end
    end

    test "raises on malformed YAML content" do
      assert_raise YamlElixir.ParsingError, fn ->
        Rules.load!(fixture_path("malformed.yaml"))
      end
    end
  end

  describe "validate!/1" do
    test "raises ArgumentError when capability_classes is missing" do
      assert_raise ArgumentError, ~r/capability_classes/, fn ->
        valid_rules_map()
        |> Map.delete("capability_classes")
        |> Rules.validate!()
      end
    end

    test "raises when a capability class is missing" do
      assert_raise ArgumentError, ~r/write_prod_low/, fn ->
        valid_rules_map(%{
          "capability_classes" =>
            Map.delete(valid_rules_map()["capability_classes"], "write_prod_low")
        })
        |> Rules.validate!()
      end
    end

    test "raises when capability_classes has an extra class" do
      assert_raise ArgumentError, ~r/break_glass/, fn ->
        valid_rules_map(%{
          "capability_classes" =>
            Map.put(valid_rules_map()["capability_classes"], "break_glass", %{
              "auto" => false,
              "audit" => true,
              "gated" => true
            })
        })
        |> Rules.validate!()
      end
    end

    test "raises when a capability class is missing a policy boolean" do
      assert_raise ArgumentError, ~r/audit/, fn ->
        caps =
          valid_rules_map()["capability_classes"]
          |> put_in(["read"], %{
            "auto" => true,
            "gated" => false
          })

        Rules.validate!(valid_rules_map(%{"capability_classes" => caps}))
      end
    end

    test "raises when a capability class policy field is not boolean" do
      assert_raise ArgumentError, ~r/gated/, fn ->
        caps =
          put_in(valid_rules_map()["capability_classes"], ["write_prod_high", "gated"], "yes")

        Rules.validate!(valid_rules_map(%{"capability_classes" => caps}))
      end
    end

    test "raises when write_prod_high is not gated" do
      assert_raise ArgumentError, ~r/write_prod_high.*gated/, fn ->
        caps =
          put_in(valid_rules_map()["capability_classes"], ["write_prod_high", "gated"], false)

        Rules.validate!(valid_rules_map(%{"capability_classes" => caps}))
      end
    end

    test "raises when kubectl_verbs is missing a class key" do
      assert_raise ArgumentError, ~r/write_dev/, fn ->
        valid_rules_map(%{
          "kubectl_verbs" => Map.delete(valid_rules_map()["kubectl_verbs"], "write_dev")
        })
        |> Rules.validate!()
      end
    end

    test "raises when kubectl_verbs top-level key is missing" do
      assert_raise ArgumentError, ~r/kubectl_verbs/, fn ->
        valid_rules_map()
        |> Map.delete("kubectl_verbs")
        |> Rules.validate!()
      end
    end

    test "raises when function_blocklist top-level key is missing" do
      assert_raise ArgumentError, ~r/function_blocklist/, fn ->
        valid_rules_map()
        |> Map.delete("function_blocklist")
        |> Rules.validate!()
      end
    end

    test "raises when kubectl_verbs has an extra class key" do
      assert_raise ArgumentError, ~r/break_glass/, fn ->
        valid_rules_map(%{
          "kubectl_verbs" => Map.put(valid_rules_map()["kubectl_verbs"], "break_glass", [])
        })
        |> Rules.validate!()
      end
    end

    test "raises when kubectl_verbs value is not a list of strings" do
      for class <- ~w(read write_dev write_prod_low write_prod_high),
          bad_value <- ["get", [:get], ["get", :logs]] do
        assert_raise ArgumentError, ~r/#{class}/, fn ->
          verbs = put_in(valid_rules_map()["kubectl_verbs"][class], bad_value)
          Rules.validate!(valid_rules_map(%{"kubectl_verbs" => verbs}))
        end
      end
    end

    test "raises when function_blocklist is not a list of strings" do
      for bad_value <- [
            "pg_terminate_backend",
            [:pg_terminate_backend],
            ["pg_cancel_backend", :dblink]
          ] do
        assert_raise ArgumentError, fn ->
          Rules.validate!(valid_rules_map(%{"function_blocklist" => bad_value}))
        end
      end
    end

    test "defaults absent routing, profile, and kubectl sections to empty maps" do
      rules = Rules.validate!(valid_rules_map())

      assert rules.__struct__ == Rules
      assert rules.investigator_profiles == %{}
      assert rules.alert_class_routing == %{}
      assert rules.kubectl_config == %{}
    end

    test "preserves present kubectl config map with string keys" do
      kubectl_config = %{"binary" => "/usr/local/bin/kubectl", "default_timeout_ms" => 60_000}

      rules = Rules.validate!(valid_rules_map(%{"kubectl" => kubectl_config}))

      assert rules.kubectl_config == kubectl_config
    end

    test "raises when kubectl config is not a map" do
      assert_raise ArgumentError, ~r/kubectl_config must be a map/, fn ->
        valid_rules_map(%{"kubectl" => "not a map"})
        |> Rules.validate!()
      end
    end

    test "preserves present routing and profile maps" do
      profiles = %{"db" => %{"tools" => ["query_db"]}}
      routing = %{"DatabaseConnectionsSaturated" => ["db", "prometheus"]}

      rules =
        Rules.validate!(
          valid_rules_map(%{
            "investigator_profiles" => profiles,
            "alert_class_routing" => routing
          })
        )

      assert rules.__struct__ == Rules
      assert rules.investigator_profiles == profiles
      assert rules.alert_class_routing == routing
    end

    test "raises when optional routing or profile sections are not maps" do
      for key <- ["investigator_profiles", "alert_class_routing"] do
        assert_raise ArgumentError, ~r/#{key}/, fn ->
          valid_rules_map(%{key => []})
          |> Rules.validate!()
        end
      end
    end
  end

  test "policy_for/2 returns the correct policy map for each class" do
    rules = Rules.validate!(valid_rules_map())

    for class <- @classes do
      assert Rules.policy_for(rules, class) == Map.fetch!(rules.capability_classes, class)
    end
  end

  describe "Agent" do
    test "boots and serves the parsed rules struct" do
      pid = start_supervised!({RulesAgent, path: fixture_path("default.yaml")})

      rules = RulesAgent.get(pid)

      assert rules.__struct__ == Rules
    end

    test "raises on invalid config (fail-closed boot)" do
      assert_raise YamlElixir.ParsingError, fn ->
        RulesAgent.start_link(path: fixture_path("malformed.yaml"))
      end
    end

    test "is started without a registered name" do
      {:ok, pid} =
        RulesAgent.start_link(path: fixture_path("default.yaml"), name: :should_be_ignored)

      on_exit(fn ->
        if Process.alive?(pid), do: Agent.stop(pid, :normal, :infinity)
      end)

      assert Process.info(pid, :registered_name) == {:registered_name, []}
    end
  end
end
