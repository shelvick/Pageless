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
      write_prod_high: ["rollout undo", "delete", "scale-down", "scale", "apply"]
    }
  end

  defp net_new_forbidden_flag_stems do
    ~w(--server --insecure-skip-tls-verify --certificate-authority --client-key --client-certificate --token-file --proxy-url --context --cluster --user --request-timeout -A --all-namespaces)
  end

  defp net_new_forbidden_flag_tokens do
    net_new_forbidden_flag_stems()
    |> Enum.flat_map(fn
      "-A" -> ["-A"]
      flag -> [flag, "#{flag}=value"]
    end)
  end

  defp read_verbs, do: default_verb_table().read

  defp insert_tokens(args, index, tokens) do
    {left, right} = Enum.split(args, index)
    left ++ tokens ++ right
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

    test "rejects exec as a forbidden verb regardless of verb_table contents" do
      # Even if a (misconfigured or malicious) verb table lists exec under
      # write_prod_high, the classifier rejects it structurally.
      verb_table = Map.update!(default_verb_table(), :write_prod_high, &["exec" | &1])

      assert VerbTableClassifier.classify(
               ["exec", "-it", "pod/foo", "--", "bash"],
               verb_table
             ) == {:error, {:forbidden_verb, "exec"}}
    end

    test "rejects cp/port-forward/debug/attach as forbidden verbs" do
      for verb <- ["cp", "port-forward", "debug", "attach"] do
        assert VerbTableClassifier.classify([verb, "pod/foo"], default_verb_table()) ==
                 {:error, {:forbidden_verb, verb}},
               "expected #{verb} to be rejected as a forbidden verb"
      end
    end

    test "case-folds the forbidden-verb check" do
      assert VerbTableClassifier.classify(["EXEC", "-it", "pod/foo"], default_verb_table()) ==
               {:error, {:forbidden_verb, "EXEC"}}
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

    test "returns :malformed_args for dangling namespace flag" do
      assert VerbTableClassifier.classify(["-n"], default_verb_table()) ==
               {:error, :malformed_args}
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

    test "rejects --as standalone flag form" do
      assert VerbTableClassifier.classify(
               ["get", "pods", "--as", "system:admin"],
               default_verb_table()
             ) == {:error, {:forbidden_flag, "--as"}}
    end

    test "rejects --as=value inline flag form" do
      assert VerbTableClassifier.classify(
               ["get", "pods", "--as=system:admin"],
               default_verb_table()
             ) == {:error, {:forbidden_flag, "--as=system:admin"}}
    end

    test "rejects each forbidden flag in both forms" do
      for flag <- ["--raw", "--token", "--as", "--as-group", "--kubeconfig"] do
        assert VerbTableClassifier.classify(["get", "pods", flag, "value"], default_verb_table()) ==
                 {:error, {:forbidden_flag, flag}}

        inline = "#{flag}=value"

        assert VerbTableClassifier.classify(["get", "pods", inline], default_verb_table()) ==
                 {:error, {:forbidden_flag, inline}}
      end
    end

    test "prefix-shared --asynchronous-mode falls through to :write_prod_high" do
      assert VerbTableClassifier.classify(
               ["--asynchronous-mode", "get", "pods"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "--asynchronous-mode"}

      assert VerbTableClassifier.classify(
               ["--as", "system:admin", "get", "pods"],
               default_verb_table()
             ) ==
               {:error, {:forbidden_flag, "--as"}}
    end

    test "rejects forbidden flag positioned before the verb" do
      assert VerbTableClassifier.classify(
               ["--kubeconfig=/etc/k8s.conf", "get", "pods"],
               default_verb_table()
             ) == {:error, {:forbidden_flag, "--kubeconfig=/etc/k8s.conf"}}
    end

    test "rejects 'secrets' resource for any verb" do
      for verb <- ["get", "describe", "delete"] do
        assert VerbTableClassifier.classify([verb, "secrets"], default_verb_table()) ==
                 {:error, {:forbidden_resource, "secrets"}}
      end
    end

    test "rejects path-form secrets/name resource" do
      assert VerbTableClassifier.classify(["describe", "secrets/api-key"], default_verb_table()) ==
               {:error, {:forbidden_resource, "secrets/api-key"}}
    end

    test "rejects api-group path-form secrets resource" do
      assert VerbTableClassifier.classify(
               ["describe", "secrets.v1/api-key"],
               default_verb_table()
             ) ==
               {:error, {:forbidden_resource, "secrets.v1/api-key"}}
    end

    test "rejects serviceaccounts, serviceaccount, and sa" do
      for resource <- ["serviceaccounts", "serviceaccount", "sa"] do
        assert VerbTableClassifier.classify(["get", resource], default_verb_table()) ==
                 {:error, {:forbidden_resource, resource}}
      end
    end

    test "rejects tokens, token, bootstraptokens" do
      for resource <- ["tokens", "token", "bootstraptokens"] do
        assert VerbTableClassifier.classify(["get", resource], default_verb_table()) ==
                 {:error, {:forbidden_resource, resource}}
      end
    end

    test "matches forbidden resources case-insensitively" do
      for resource <- ["Secrets", "SECRETS"] do
        assert VerbTableClassifier.classify(["get", resource], default_verb_table()) ==
                 {:error, {:forbidden_resource, resource}}
      end
    end

    test "finds forbidden resource past intermediate flags" do
      assert VerbTableClassifier.classify(
               ["get", "-n", "kube-system", "secrets"],
               default_verb_table()
             ) == {:error, {:forbidden_resource, "secrets"}}
    end

    test "finds forbidden resource after output flag value" do
      assert VerbTableClassifier.classify(
               ["get", "-o", "json", "secrets"],
               default_verb_table()
             ) == {:error, {:forbidden_resource, "secrets"}}
    end

    test "finds forbidden resource after another resource token" do
      assert VerbTableClassifier.classify(["get", "pods", "secrets"], default_verb_table()) ==
               {:error, {:forbidden_resource, "secrets"}}
    end

    test "finds forbidden resource inside comma-separated resource token" do
      assert VerbTableClassifier.classify(["get", "pods,secrets"], default_verb_table()) ==
               {:error, {:forbidden_resource, "secrets"}}
    end

    test "allows non-forbidden resources while still rejecting forbidden resources" do
      assert VerbTableClassifier.classify(["get", "pods"], default_verb_table()) ==
               {:ok, :read, "get"}

      assert VerbTableClassifier.classify(
               ["logs", "deployment/payments-api"],
               default_verb_table()
             ) ==
               {:ok, :read, "logs"}

      assert VerbTableClassifier.classify(
               ["rollout", "undo", "deployment/x"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "rollout undo"}

      assert VerbTableClassifier.classify(["get", "secrets/api-key"], default_verb_table()) ==
               {:error, {:forbidden_resource, "secrets/api-key"}}
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

    property "any args containing a forbidden flag rejects" do
      forbidden_flags =
        ["--raw", "--token", "--as", "--as-group", "--kubeconfig"]
        |> Enum.flat_map(fn flag -> [flag, "#{flag}=value"] end)

      verb =
        :alphanumeric
        |> StreamData.string(min_length: 1, max_length: 20)
        |> StreamData.seeded(20_260_514)

      forbidden_flag =
        forbidden_flags
        |> StreamData.member_of()
        |> StreamData.seeded(20_260_515)

      check all(random_verb <- verb, flag <- forbidden_flag, max_runs: 30) do
        assert VerbTableClassifier.classify([random_verb, flag], default_verb_table()) ==
                 {:error, {:forbidden_flag, flag}}
      end
    end

    test "rejects all 13 net-new forbidden stems in both forms" do
      for flag <- net_new_forbidden_flag_tokens() do
        assert VerbTableClassifier.classify([flag, "get", "pods"], default_verb_table()) ==
                 {:error, {:forbidden_flag, flag}}
      end
    end

    test "rejects net-new forbidden flags positioned after verb" do
      for flag <- net_new_forbidden_flag_tokens() do
        assert VerbTableClassifier.classify(["get", "pods", flag], default_verb_table()) ==
                 {:error, {:forbidden_flag, flag}}
      end
    end

    test "consumes -v and --v safe-skip flags in both forms" do
      for args <- [
            ["-v", "5", "get", "pods"],
            ["-v=5", "get", "pods"],
            ["--v", "3", "get", "pods"],
            ["--v=3", "get", "pods"],
            ["get", "pods", "-v", "5"]
          ] do
        assert VerbTableClassifier.classify(args, default_verb_table()) == {:ok, :read, "get"}
      end
    end

    test "consumes --verbose and --quiet safe-skip flags" do
      assert VerbTableClassifier.classify(["--verbose", "get", "pods"], default_verb_table()) ==
               {:ok, :read, "get"}

      assert VerbTableClassifier.classify(
               ["--quiet", "logs", "deployment/x"],
               default_verb_table()
             ) == {:ok, :read, "logs"}

      assert VerbTableClassifier.classify(
               ["--quiet=false", "get", "pods"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "--quiet=false"}

      assert VerbTableClassifier.classify(
               ["--verbose=true", "get", "pods"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "--verbose=true"}
    end

    test "unknown leading flag falls through to fail-closed" do
      assert VerbTableClassifier.classify(
               ["--label-selector=app=web", "get", "pods"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "--label-selector=app=web"}
    end

    test ":read namespace allowlist permits known namespaces and rejects unknown ones" do
      for ns <- ["prod", "monitoring", "default"] do
        assert VerbTableClassifier.classify(["get", "pods", "-n", ns], default_verb_table()) ==
                 {:ok, :read, "get"}
      end

      for {args, ns} <- [
            {["get", "pods", "-n", "kube-system"], "kube-system"},
            {["logs", "--namespace=cattle-system", "deployment/x"], "cattle-system"},
            {["describe", "pod/x", "-n", "evil-ns"], "evil-ns"}
          ] do
        assert VerbTableClassifier.classify(args, default_verb_table()) ==
                 {:error, {:forbidden_namespace, ns}}
      end
    end

    test "implicit default and write classes keep namespace policy scoped to reads" do
      assert VerbTableClassifier.classify(["get", "pods"], default_verb_table()) ==
               {:ok, :read, "get"}

      assert VerbTableClassifier.classify(
               ["rollout", "undo", "deployment/x", "-n", "kube-system"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "rollout undo"}

      assert VerbTableClassifier.classify(
               ["delete", "pod/foo", "-n", "evil-ns"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "delete"}

      assert VerbTableClassifier.classify(
               ["get", "pods", "-n", "prod", "--namespace=monitoring"],
               default_verb_table()
             ) == {:error, :malformed_args}
    end

    test "rejects multiple namespace flags as :malformed_args" do
      for args <- [
            ["get", "pods", "-n", "prod", "--namespace=monitoring"],
            ["get", "pods", "--namespace=prod", "-n", "monitoring"],
            ["get", "pods", "-n", "prod", "-n", "monitoring"],
            ["get", "pods", "--namespace=prod", "--namespace=monitoring"],
            ["-n", "prod", "--namespace=monitoring", "get", "pods"]
          ] do
        assert VerbTableClassifier.classify(args, default_verb_table()) ==
                 {:error, :malformed_args}
      end
    end

    property "every blocked namespace x every :read verb rejects" do
      blocked_namespace =
        StreamData.one_of([
          StreamData.member_of(
            ~w(kube-system kube-public kube-node-lease cattle-system tigera-operator)
          ),
          StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
        ])
        |> StreamData.filter(fn ns -> ns not in ["prod", "monitoring", "default"] end)
        |> StreamData.seeded(20_260_516)

      read_verb =
        read_verbs()
        |> StreamData.member_of()
        |> StreamData.seeded(20_260_517)

      check all(verb <- read_verb, ns <- blocked_namespace, max_runs: 40) do
        assert VerbTableClassifier.classify([verb, "-n", ns], default_verb_table()) ==
                 {:error, {:forbidden_namespace, ns}}
      end
    end

    property "safe-skip flags do not affect classification" do
      base_invocation =
        StreamData.member_of([
          {["get", "pods"], "get"},
          {["logs", "deployment/x"], "logs"},
          {["describe", "deployment/x"], "describe"}
        ])
        |> StreamData.seeded(20_260_518)

      safe_skip_tokens =
        StreamData.member_of([
          ["-v", "1"],
          ["-v=2"],
          ["--v", "3"],
          ["--v=4"],
          ["--verbose"],
          ["--quiet"]
        ])
        |> StreamData.seeded(20_260_519)

      insertion_index = StreamData.integer(0..2) |> StreamData.seeded(20_260_520)

      check all(
              {args, verb} <- base_invocation,
              tokens <- safe_skip_tokens,
              index <- insertion_index,
              max_runs: 30
            ) do
        with_safe_skip = insert_tokens(args, min(index, length(args)), tokens)

        assert VerbTableClassifier.classify(with_safe_skip, default_verb_table()) ==
                 {:ok, :read, verb}
      end
    end

    test "passes bounded positive delta --replicas=+N and rejects one over cap" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas=+10"],
               default_verb_table()
             ) == {:ok, :write_prod_low, "scale-up"}

      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas=+11"],
               default_verb_table()
             ) == {:error, {:forbidden_replicas, "+11"}}
    end

    test "passes bounded negative delta --replicas=-N and rejects one over cap" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas=-10"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "scale-down"}

      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas=-11"],
               default_verb_table()
             ) == {:error, {:forbidden_replicas, "-11"}}
    end

    test "passes bounded absolute --replicas=N and rejects one over cap" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas=20"],
               default_verb_table()
             ) == {:ok, :write_prod_high, "scale"}

      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas=21"],
               default_verb_table()
             ) == {:error, {:forbidden_replicas, "21"}}
    end

    test "rejects out-of-range --replicas magnitudes with raw value preserved" do
      for {raw, expected} <- [
            {"+10000", {:error, {:forbidden_replicas, "+10000"}}},
            {"-10000", {:error, {:forbidden_replicas, "-10000"}}},
            {"10000", {:error, {:forbidden_replicas, "10000"}}}
          ] do
        assert VerbTableClassifier.classify(
                 ["scale", "deployment/payments-api", "--replicas=#{raw}"],
                 default_verb_table()
               ) == expected
      end
    end

    test "ignores --replicas bounds for non-scale verbs" do
      for {args, verb} <- [
            {["get", "pods", "--replicas=+10000"], "get"},
            {["logs", "deployment/payments-api", "--replicas=+10000"], "logs"}
          ] do
        assert VerbTableClassifier.classify(args, default_verb_table()) == {:ok, :read, verb}
      end
    end

    test "handles separated --replicas <value> form identically to combined" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas", "+4"],
               default_verb_table()
             ) == {:ok, :write_prod_low, "scale-up"}

      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas", "+1000"],
               default_verb_table()
             ) == {:error, {:forbidden_replicas, "+1000"}}
    end

    test "rejects non-integer --replicas value as :malformed_args" do
      for args <- [
            ["scale", "deployment/payments-api", "--replicas=abc"],
            ["scale", "deployment/payments-api", "--replicas=10_000"],
            ["scale", "deployment/payments-api", "--replicas="],
            ["scale", "deployment/payments-api", "--replicas=+"],
            ["scale", "deployment/payments-api", "--replicas", "abc"],
            ["scale", "deployment/payments-api", "--replicas", "10_000"],
            ["scale", "deployment/payments-api", "--replicas", "+"]
          ] do
        assert VerbTableClassifier.classify(args, default_verb_table()) ==
                 {:error, :malformed_args}
      end
    end

    test "rejects multiple --replicas flags as :malformed_args" do
      for args <- [
            ["scale", "deployment/payments-api", "--replicas=+1", "--replicas=+10000"],
            ["scale", "deployment/payments-api", "--replicas", "+1", "--replicas", "+10000"],
            ["scale", "deployment/payments-api", "--replicas=+1", "--replicas", "+10000"],
            ["scale", "deployment/payments-api", "--replicas", "+1", "--replicas=+10000"]
          ] do
        assert VerbTableClassifier.classify(args, default_verb_table()) ==
                 {:error, :malformed_args}
      end
    end

    test "rejects dangling --replicas flag as :malformed_args" do
      assert VerbTableClassifier.classify(
               ["scale", "deployment/payments-api", "--replicas"],
               default_verb_table()
             ) == {:error, :malformed_args}
    end

    property "every out-of-bound --replicas value rejects with :forbidden_replicas" do
      out_of_bound_replicas =
        StreamData.one_of([
          StreamData.map(StreamData.integer(11..1_000_000), fn n -> "+#{n}" end),
          StreamData.map(StreamData.integer(11..1_000_000), fn n -> "-#{n}" end),
          StreamData.map(StreamData.integer(21..1_000_000), fn n -> "#{n}" end)
        ])
        |> StreamData.seeded(20_260_521)

      check all(raw <- out_of_bound_replicas, max_runs: 50) do
        assert VerbTableClassifier.classify(
                 ["scale", "deployment/payments-api", "--replicas=#{raw}"],
                 default_verb_table()
               ) == {:error, {:forbidden_replicas, raw}}
      end
    end
  end

  describe "extract_verb/1" do
    test "applies WG-VerbTableHardening strip semantics" do
      assert VerbTableClassifier.extract_verb(["-v", "5", "get", "pods"]) == {:ok, "get"}

      assert VerbTableClassifier.extract_verb(["-n", "prod", "get", "pods"]) ==
               {:ok, "get"}

      assert VerbTableClassifier.extract_verb(["--namespace=prod", "logs", "deployment/x"]) ==
               {:ok, "logs"}

      assert VerbTableClassifier.extract_verb(["--asynchronous-mode", "get", "pods"]) ==
               {:ok, "--asynchronous-mode"}

      assert VerbTableClassifier.extract_verb(["--as=system:admin", "get", "pods"]) ==
               {:ok, "--as=system:admin"}
    end
  end
end
