defmodule Pageless.Governance.VerbTableClassifierTest do
  @moduledoc "Tests Packet 2 kubectl verb-table classifier behavior."

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pageless.Governance.VerbTableClassifier

  defp default_verb_table do
    %{
      read: ["get", "logs", "describe", "events", "top"],
      write_dev: [],
      write_prod_low: ["rollout restart", "scale-up"],
      write_prod_high: ["rollout undo", "delete", "scale-down", "scale", "apply", "exec"]
    }
  end

  describe "classify/2" do
    test "classifies 'get pods' as :read" do
      assert VerbTableClassifier.classify(["get", "pods"], default_verb_table()) ==
               {:ok, :read, "get"}
    end

    test "classifies 'logs' with flags as :read" do
      assert VerbTableClassifier.classify(
               ["logs", "-n", "prod", "deployment/payments-api", "--since=10m"],
               default_verb_table()
             ) == {:ok, :read, "logs"}
    end

    test "classifies describe, events, top as :read" do
      for {args, verb} <- [
            {["describe", "deployment/x"], "describe"},
            {["events", "-n", "prod"], "events"},
            {["top", "nodes"], "top"}
          ] do
        assert VerbTableClassifier.classify(args, default_verb_table()) == {:ok, :read, verb}
      end
    end

    test "classifies 'rollout restart' as :write_prod_low" do
      assert VerbTableClassifier.classify(
               ["rollout", "restart", "deployment/payments-api"],
               default_verb_table()
             ) == {:ok, :write_prod_low, "rollout restart"}
    end

    test "classifies 'rollout undo' as :write_prod_high (B5 money beat)" do
      assert VerbTableClassifier.classify(
               ["rollout", "undo", "deployment/payments-api", "-n", "prod"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "rollout undo"}
    end

    test "classifies scale with --replicas=+N as scale-up :write_prod_low" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/x", "--replicas=+4"],
               default_verb_table()
             ) == {:ok, :write_prod_low, "scale-up"}
    end

    test "finds --replicas=+N regardless of position" do
      assert VerbTableClassifier.classify(
               ["scale", "--replicas=+2", "deployment/foo"],
               default_verb_table()
             ) == {:ok, :write_prod_low, "scale-up"}
    end

    test "classifies separated --replicas +N as scale-up regardless of position" do
      for args <- [
            ["scale", "deployment/foo", "--replicas", "+2"],
            ["scale", "--replicas", "+2", "deployment/foo"]
          ] do
        assert VerbTableClassifier.classify(args, default_verb_table()) ==
                 {:ok, :write_prod_low, "scale-up"}
      end
    end

    test "classifies scale with --replicas=-N as scale-down :write_prod_high" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/foo", "--replicas=-2"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "scale-down"}
    end

    test "classifies separated --replicas -N as scale-down" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/foo", "--replicas", "-2"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "scale-down"}
    end

    test "treats absolute --replicas=N as scale (conservative)" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/foo", "--replicas=5"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "scale"}
    end

    test "classifies delete as :write_prod_high" do
      assert VerbTableClassifier.classify(["delete", "pod/foo"], default_verb_table()) ==
               {:ok, :write_prod_high, "delete"}
    end

    test "classifies apply as :write_prod_high" do
      assert VerbTableClassifier.classify(["apply", "-f", "foo.yaml"], default_verb_table()) ==
               {:ok, :write_prod_high, "apply"}
    end

    test "classifies exec as :write_prod_high" do
      assert VerbTableClassifier.classify(
               ["exec", "-it", "pod/foo", "--", "bash"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "exec"}
    end

    test "defaults unknown verbs to :write_prod_high" do
      assert VerbTableClassifier.classify(["completely-made-up-verb"], default_verb_table()) ==
               {:ok, :write_prod_high, "completely-made-up-verb"}
    end

    test "defaults unknown compound verbs to :write_prod_high" do
      assert VerbTableClassifier.classify(
               ["rollout", "made-up-subcommand"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "rollout made-up-subcommand"}
    end

    test "strips leading -n flag and its value" do
      assert VerbTableClassifier.classify(["-n", "prod", "get", "pods"], default_verb_table()) ==
               {:ok, :read, "get"}
    end

    test "strips leading --namespace= combined flag" do
      assert VerbTableClassifier.classify(
               ["--namespace=prod", "logs", "deployment/foo"],
               default_verb_table()
             ) == {:ok, :read, "logs"}
    end

    test "returns :empty_args for empty list" do
      assert VerbTableClassifier.classify([], default_verb_table()) == {:error, :empty_args}
    end

    test "returns :empty_args when only flags remain" do
      assert VerbTableClassifier.classify(["-n"], default_verb_table()) == {:error, :empty_args}
    end

    test "returns :malformed_args when args contain non-binary" do
      assert VerbTableClassifier.classify([nil], default_verb_table()) ==
               {:error, :malformed_args}
    end

    test "with empty verb table defaults all verbs to :write_prod_high" do
      empty_table = %{read: [], write_dev: [], write_prod_low: [], write_prod_high: []}

      assert VerbTableClassifier.classify(["get", "pods"], empty_table) ==
               {:ok, :write_prod_high, "get"}
    end

    property "any verb not in supplied table classifies as :write_prod_high" do
      known_verbs =
        default_verb_table()
        |> Map.values()
        |> List.flatten()
        |> MapSet.new()

      unknown_verb =
        StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
        |> StreamData.filter(fn verb -> not MapSet.member?(known_verbs, verb) end)

      check all(verb <- unknown_verb, max_runs: 50) do
        assert VerbTableClassifier.classify([verb], default_verb_table()) ==
                 {:ok, :write_prod_high, verb}
      end
    end
  end

  describe "extract_verb/1" do
    test "returns the same verb classify/2 uses internally" do
      args = ["--context=prod", "rollout", "undo", "deployment/payments-api", "-n", "prod"]

      assert VerbTableClassifier.extract_verb(args) == {:ok, "rollout undo"}

      assert VerbTableClassifier.classify(args, default_verb_table()) ==
               {:ok, :write_prod_high, "rollout undo"}
    end
  end
end
