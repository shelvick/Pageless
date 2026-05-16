defmodule Pageless.AuditTrailTest do
  @moduledoc "Tests Packet 1 audit-trail persistence and claim semantics."

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Pageless.AuditTrail
  alias Pageless.Repo

  setup do
    sandbox_owner = Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(sandbox_owner) end)
    %{sandbox_owner: sandbox_owner}
  end

  defp valid_attrs(overrides \\ %{}) do
    overrides = Map.new(overrides)

    Map.merge(
      %{
        request_id: unique("req"),
        alert_id: unique("alert"),
        agent_id: Ecto.UUID.generate(),
        agent_pid_inspect: inspect(self()),
        tool: "kubectl",
        args: %{"argv" => ["get", "pods"]},
        extracted_verb: "get",
        classification: "read",
        decision: "execute"
      },
      overrides
    )
  end

  defp unique(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp insert_decision!(overrides) do
    attrs = valid_attrs(overrides)
    assert {:ok, decision} = AuditTrail.record_decision(attrs)
    assert decision.__struct__ == decision_module()
    decision
  end

  defp assert_changeset_error(changeset, field) do
    assert %Ecto.Changeset{} = changeset
    assert Keyword.has_key?(changeset.errors, field)
  end

  defp decision_module do
    Pageless.AuditTrail.Decision
  end

  describe "record_decision/1" do
    test "inserts an execute-class row and returns it" do
      attrs = valid_attrs()

      assert {:ok, decision} = AuditTrail.record_decision(attrs)
      assert Ecto.UUID.cast(decision.id) == {:ok, decision.id}
      assert decision.request_id == attrs.request_id
      assert decision.gate_id == nil
      assert decision.alert_id == attrs.alert_id
      assert decision.agent_id == attrs.agent_id
      assert decision.agent_pid_inspect == attrs.agent_pid_inspect
      assert decision.tool == "kubectl"
      assert decision.args == %{"argv" => ["get", "pods"]}
      assert decision.extracted_verb == "get"
      assert decision.classification == "read"
      assert decision.decision == "execute"

      persisted = Repo.get!(decision_module(), decision.id)
      assert persisted.request_id == attrs.request_id
      assert persisted.decision == "execute"
      assert persisted.gate_id == nil
    end

    test "inserts a gated row with the supplied gate_id" do
      gate_id = unique("gate")

      assert {:ok, decision} =
               AuditTrail.record_decision(
                 valid_attrs(%{
                   gate_id: gate_id,
                   classification: "write_prod_high",
                   decision: "gated"
                 })
               )

      assert decision.gate_id == gate_id
      assert decision.classification == "write_prod_high"
      assert decision.decision == "gated"
    end

    test "errors when decision is gated and gate_id is missing" do
      assert {:error, changeset} =
               AuditTrail.record_decision(
                 valid_attrs(%{classification: "write_prod_high", decision: "gated"})
               )

      assert_changeset_error(changeset, :gate_id)
    end

    test "rejects invalid tool name" do
      assert {:error, changeset} = AuditTrail.record_decision(valid_attrs(%{tool: "rm_rf"}))
      assert_changeset_error(changeset, :tool)
    end

    test "restricts unknown tool to profile_violation" do
      assert {:error, changeset} =
               AuditTrail.record_decision(
                 valid_attrs(%{
                   tool: "unknown",
                   args: %{"function_name" => "steal_secrets", "raw_args" => %{}},
                   decision: "execute"
                 })
               )

      assert_changeset_error(changeset, :tool)
    end

    test "validates unknown-tool args" do
      for args <- [%{}, %{"function_name" => "steal_secrets"}, %{"raw_args" => %{}}] do
        assert {:error, changeset} =
                 AuditTrail.record_decision(
                   valid_attrs(%{
                     tool: "unknown",
                     args: args,
                     decision: "profile_violation",
                     result_status: "error",
                     result_summary: ":out_of_scope_tool"
                   })
                 )

        assert_changeset_error(changeset, :args)
      end
    end

    test "rejects unknown classification" do
      assert {:error, changeset} =
               AuditTrail.record_decision(valid_attrs(%{classification: "root"}))

      assert_changeset_error(changeset, :classification)
    end

    test "rejects unknown decision value" do
      assert {:error, changeset} = AuditTrail.record_decision(valid_attrs(%{decision: "maybe"}))
      assert_changeset_error(changeset, :decision)
    end

    test "rejects direct inserts into post-classification states" do
      for decision <- ["approved", "denied", "executed", "execution_failed"] do
        attrs =
          valid_attrs(%{
            decision: decision,
            operator_ref: "operator-1",
            denial_reason: "blocked",
            result_status: "ok",
            result_summary: "done"
          })

        assert {:error, changeset} = AuditTrail.record_decision(attrs)
        assert_changeset_error(changeset, :decision)
      end
    end

    test "rejects invalid terminal result_status values" do
      decision = insert_decision!(decision: "execute")

      assert {:error, changeset} =
               AuditTrail.update_decision(decision, %{
                 decision: "executed",
                 result_status: "maybe",
                 result_summary: "done"
               })

      assert_changeset_error(changeset, :result_status)
    end

    test "rejects duplicate gate_id" do
      gate_id = unique("gate")
      insert_decision!(gate_id: gate_id, classification: "write_prod_high", decision: "gated")

      assert {:error, changeset} =
               AuditTrail.record_decision(
                 valid_attrs(%{
                   gate_id: gate_id,
                   classification: "write_prod_high",
                   decision: "gated"
                 })
               )

      assert_changeset_error(changeset, :gate_id)
    end

    test "allows multiple rows with NULL gate_id" do
      assert {:ok, %{gate_id: nil}} = AuditTrail.record_decision(valid_attrs())
      assert {:ok, %{gate_id: nil}} = AuditTrail.record_decision(valid_attrs())
    end

    test "args map roundtrips through jsonb" do
      args = %{"argv" => ["rollout", "undo", "deployment/payments-api"]}
      gate_id = unique("gate")

      insert_decision!(
        gate_id: gate_id,
        args: args,
        extracted_verb: "rollout undo",
        classification: "write_prod_high",
        decision: "gated"
      )

      assert %{args: ^args} = AuditTrail.get_by_gate_id(gate_id)
    end

    test "accepts profile_violation as initial terminal decision" do
      attrs =
        valid_attrs(%{
          tool: "unknown",
          args: %{"function_name" => "steal_secrets", "raw_args" => %{"kind" => "prompt"}},
          extracted_verb: nil,
          classification: "read",
          decision: "profile_violation",
          result_status: "error",
          result_summary: ":out_of_scope_tool"
        })

      assert {:ok, decision} = AuditTrail.record_decision(attrs)
      assert decision.decision == "profile_violation"
      assert decision.tool == "unknown"
      assert decision.gate_id == nil
      assert decision.operator_ref == nil
      assert decision.result_status == "error"
      assert decision.result_summary == ":out_of_scope_tool"
    end

    test "accepts budget_exhausted as initial terminal decision" do
      attrs =
        valid_attrs(%{
          classification: "read",
          decision: "budget_exhausted",
          result_status: "error",
          result_summary: ":budget_exhausted"
        })

      assert {:ok, decision} = AuditTrail.record_decision(attrs)
      assert decision.decision == "budget_exhausted"
      assert decision.gate_id == nil
      assert decision.operator_ref == nil
      assert decision.result_status == "error"
      assert decision.result_summary == ":budget_exhausted"
    end

    test "requires result fields on profile_violation" do
      for overrides <- [
            %{result_status: "ok", result_summary: ":out_of_scope_tool"},
            %{result_status: nil, result_summary: ":out_of_scope_tool"},
            %{result_status: "error", result_summary: nil},
            %{result_status: "error", result_summary: ""}
          ] do
        attrs =
          valid_attrs(
            Map.merge(
              %{
                decision: "profile_violation",
                result_status: "error",
                result_summary: ":out_of_scope_tool"
              },
              overrides
            )
          )

        assert {:error, changeset} = AuditTrail.record_decision(attrs)

        if overrides.result_status != "error" do
          assert_changeset_error(changeset, :result_status)
        end

        if is_nil(overrides.result_summary) or overrides.result_summary == "" do
          assert_changeset_error(changeset, :result_summary)
        end
      end
    end

    test "rejects gate_id on profile_violation rows" do
      assert {:error, changeset} =
               AuditTrail.record_decision(
                 valid_attrs(%{
                   gate_id: unique("gate"),
                   decision: "profile_violation",
                   result_status: "error",
                   result_summary: ":verb_not_in_profile"
                 })
               )

      assert_changeset_error(changeset, :gate_id)
    end

    test "rejects gate_id on budget_exhausted rows" do
      assert {:error, changeset} =
               AuditTrail.record_decision(
                 valid_attrs(%{
                   gate_id: unique("gate"),
                   decision: "budget_exhausted",
                   result_status: "error",
                   result_summary: ":budget_exhausted"
                 })
               )

      assert_changeset_error(changeset, :gate_id)
    end

    test "requires canonical budget_exhausted result" do
      for overrides <- [
            %{result_status: "ok", result_summary: ":budget_exhausted"},
            %{result_status: nil, result_summary: ":budget_exhausted"},
            %{result_status: "error", result_summary: ":other_reason"},
            %{result_status: "error", result_summary: nil}
          ] do
        attrs =
          valid_attrs(
            Map.merge(
              %{
                decision: "budget_exhausted",
                result_status: "error",
                result_summary: ":budget_exhausted"
              },
              overrides
            )
          )

        assert {:error, changeset} = AuditTrail.record_decision(attrs)

        if overrides.result_status != "error" do
          assert_changeset_error(changeset, :result_status)
        end

        if overrides.result_summary != ":budget_exhausted" do
          assert_changeset_error(changeset, :result_summary)
        end
      end
    end

    test "rejects operator fields on pre-gate rows" do
      for decision <- ["profile_violation", "budget_exhausted"],
          field <- [:operator_ref, :denial_reason] do
        attrs =
          %{field => "operator-data"}
          |> Map.merge(%{
            decision: decision,
            result_status: "error",
            result_summary: terminal_summary(decision)
          })
          |> valid_attrs()

        assert {:error, changeset} = AuditTrail.record_decision(attrs)
        assert_changeset_error(changeset, field)
      end
    end
  end

  describe "get_by_gate_id/1" do
    test "returns the row for an existing gate_id" do
      gate_id = unique("gate")

      inserted =
        insert_decision!(gate_id: gate_id, classification: "write_prod_high", decision: "gated")

      assert found = AuditTrail.get_by_gate_id(gate_id)
      assert found.id == inserted.id
    end

    test "returns nil when gate_id is not found" do
      assert AuditTrail.get_by_gate_id(unique("gate")) == nil
    end
  end

  describe "update_decision/2" do
    test "transitions gated row to approved with operator_ref" do
      decision =
        insert_decision!(
          gate_id: unique("gate"),
          classification: "write_prod_high",
          decision: "gated"
        )

      assert {:ok, updated} =
               AuditTrail.update_decision(decision, %{
                 decision: "approved",
                 operator_ref: "operator-1"
               })

      assert updated.decision == "approved"
      assert updated.operator_ref == "operator-1"
    end

    test "transitions gated row to denied with reason" do
      decision =
        insert_decision!(
          gate_id: unique("gate"),
          classification: "write_prod_high",
          decision: "gated"
        )

      assert {:ok, updated} =
               AuditTrail.update_decision(decision, %{
                 decision: "denied",
                 operator_ref: "operator-1",
                 denial_reason: "too risky"
               })

      assert updated.decision == "denied"
      assert updated.operator_ref == "operator-1"
      assert updated.denial_reason == "too risky"
    end

    test "requires denial_reason when transitioning to denied" do
      decision =
        insert_decision!(
          gate_id: unique("gate"),
          classification: "write_prod_high",
          decision: "gated"
        )

      assert {:error, changeset} =
               AuditTrail.update_decision(decision, %{
                 decision: "denied",
                 operator_ref: "operator-1"
               })

      assert_changeset_error(changeset, :denial_reason)
    end

    test "records executed status from executable states" do
      decisions = [
        approved_decision(),
        insert_decision!(decision: "execute"),
        insert_decision!(decision: "audit_and_execute")
      ]

      for decision <- decisions do
        assert {:ok, updated} =
                 AuditTrail.update_decision(decision, %{
                   decision: "executed",
                   result_status: "ok",
                   result_summary: "completed"
                 })

        assert updated.decision == "executed"
        assert updated.result_status == "ok"
        assert updated.result_summary == "completed"
      end
    end

    test "records execution_failed from executable states" do
      decisions = [
        approved_decision(),
        insert_decision!(decision: "execute"),
        insert_decision!(decision: "audit_and_execute")
      ]

      for decision <- decisions do
        assert {:ok, updated} =
                 AuditTrail.update_decision(decision, %{
                   decision: "execution_failed",
                   result_status: "error",
                   result_summary: "command failed"
                 })

        assert updated.decision == "execution_failed"
        assert updated.result_status == "error"
        assert updated.result_summary == "command failed"
      end
    end

    test "requires result fields for execution terminal states" do
      for terminal <- ["executed", "execution_failed"] do
        decision = insert_decision!(decision: "execute")

        assert {:error, changeset} = AuditTrail.update_decision(decision, %{decision: terminal})
        assert_changeset_error(changeset, :result_status)
        assert_changeset_error(changeset, :result_summary)
      end
    end

    test "rejects execute to denied transition" do
      decision = insert_decision!(decision: "execute")

      assert {:error, changeset} =
               AuditTrail.update_decision(decision, %{
                 decision: "denied",
                 operator_ref: "operator-1",
                 denial_reason: "not pending"
               })

      assert_changeset_error(changeset, :decision)
    end

    test "rejects executed to approved transition" do
      decision =
        insert_decision!(decision: "execute")
        |> execute_decision!()

      assert {:error, changeset} =
               AuditTrail.update_decision(decision, %{
                 decision: "approved",
                 operator_ref: "operator-1"
               })

      assert_changeset_error(changeset, :decision)
    end

    test "rejects denied to executed transition" do
      decision =
        insert_decision!(
          gate_id: unique("gate"),
          classification: "write_prod_high",
          decision: "gated"
        )
        |> deny_decision!()

      assert {:error, changeset} =
               AuditTrail.update_decision(decision, %{
                 decision: "executed",
                 result_status: "ok",
                 result_summary: "should not run"
               })

      assert_changeset_error(changeset, :decision)
    end

    test "rejects rejected to executed transition" do
      decision = insert_decision!(decision: "rejected")

      assert {:error, changeset} =
               AuditTrail.update_decision(decision, %{
                 decision: "executed",
                 result_status: "ok",
                 result_summary: "should not run"
               })

      assert_changeset_error(changeset, :decision)
    end

    test "rejects any transition out of profile_violation" do
      decision =
        insert_decision!(
          decision: "profile_violation",
          result_status: "error",
          result_summary: ":table_not_in_profile_allowlist"
        )

      for target <- terminal_transition_targets("profile_violation") do
        assert {:error, changeset} =
                 AuditTrail.update_decision(decision, terminal_attrs(target))

        assert_changeset_error(changeset, :decision)
      end
    end

    test "rejects any transition out of budget_exhausted" do
      decision =
        insert_decision!(
          decision: "budget_exhausted",
          result_status: "error",
          result_summary: ":budget_exhausted"
        )

      for target <- terminal_transition_targets("budget_exhausted") do
        assert {:error, changeset} =
                 AuditTrail.update_decision(decision, terminal_attrs(target))

        assert_changeset_error(changeset, :decision)
      end
    end

    test "rejects transitions INTO terminal pre-gate decisions" do
      decisions = [
        insert_decision!(
          gate_id: unique("gate"),
          classification: "write_prod_high",
          decision: "gated"
        ),
        insert_decision!(decision: "execute"),
        approved_decision()
      ]

      for decision <- decisions,
          target <- ["profile_violation", "budget_exhausted"] do
        assert {:error, changeset} =
                 AuditTrail.update_decision(decision, terminal_attrs(target))

        assert_changeset_error(changeset, :decision)
      end
    end
  end

  describe "claim gates" do
    test "claim_gate_for_approval/2 claims only gated rows" do
      gate_id = unique("gate")
      insert_decision!(gate_id: gate_id, classification: "write_prod_high", decision: "gated")

      assert {:ok, decision} =
               AuditTrail.claim_gate_for_approval(gate_id, "operator-1")

      assert decision.decision == "approved"
      assert decision.operator_ref == "operator-1"
    end

    test "claim_gate_for_approval/2 rejects already resolved gates" do
      gate_id = unique("gate")
      insert_decision!(gate_id: gate_id, classification: "write_prod_high", decision: "gated")
      assert {:ok, _decision} = AuditTrail.claim_gate_for_approval(gate_id, "operator-1")

      assert {:error, :no_pending_gate} =
               AuditTrail.claim_gate_for_approval(gate_id, "operator-2")

      assert %{decision: "approved", operator_ref: "operator-1"} =
               AuditTrail.get_by_gate_id(gate_id)
    end

    test "claim_gate_for_denial/3 claims only gated rows" do
      gate_id = unique("gate")
      insert_decision!(gate_id: gate_id, classification: "write_prod_high", decision: "gated")

      assert {:ok, decision} =
               AuditTrail.claim_gate_for_denial(gate_id, "operator-1", "unsafe")

      assert decision.decision == "denied"
      assert decision.operator_ref == "operator-1"
      assert decision.denial_reason == "unsafe"
    end

    test "claim_gate_for_denial/3 rejects already resolved gates" do
      gate_id = unique("gate")
      insert_decision!(gate_id: gate_id, classification: "write_prod_high", decision: "gated")

      assert {:ok, _decision} =
               AuditTrail.claim_gate_for_denial(gate_id, "operator-1", "unsafe")

      assert {:error, :no_pending_gate} =
               AuditTrail.claim_gate_for_denial(gate_id, "operator-2", "late")

      assert %{decision: "denied", operator_ref: "operator-1"} =
               AuditTrail.get_by_gate_id(gate_id)
    end

    test "claim_gate_for_approval/2 resolves exactly once under concurrency", %{
      sandbox_owner: sandbox_owner
    } do
      gate_id = unique("gate")
      insert_decision!(gate_id: gate_id, classification: "write_prod_high", decision: "gated")

      results =
        ["operator-1", "operator-2"]
        |> Enum.map(fn operator ->
          Task.async(fn ->
            Sandbox.allow(Repo, sandbox_owner, self())
            AuditTrail.claim_gate_for_approval(gate_id, operator)
          end)
        end)
        |> Task.await_many(5_000)

      assert Enum.count(results, &match?({:ok, %{decision: "approved"}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :no_pending_gate}, &1)) == 1
    end

    test "claim_gate_for_approval and denial race resolves one outcome only", %{
      sandbox_owner: sandbox_owner
    } do
      gate_id = unique("gate")
      insert_decision!(gate_id: gate_id, classification: "write_prod_high", decision: "gated")

      tasks = [
        Task.async(fn ->
          Sandbox.allow(Repo, sandbox_owner, self())
          AuditTrail.claim_gate_for_approval(gate_id, "operator-approve")
        end),
        Task.async(fn ->
          Sandbox.allow(Repo, sandbox_owner, self())
          AuditTrail.claim_gate_for_denial(gate_id, "operator-deny", "unsafe")
        end)
      ]

      results = Task.await_many(tasks, 5_000)

      assert Enum.count(results, &match?({:ok, %{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :no_pending_gate}, &1)) == 1
      assert %{decision: decision} = AuditTrail.get_by_gate_id(gate_id)
      assert decision in ["approved", "denied"]
    end
  end

  defp terminal_summary("profile_violation"), do: ":out_of_scope_tool"
  defp terminal_summary("budget_exhausted"), do: ":budget_exhausted"

  defp terminal_transition_targets(current) do
    [
      "gated",
      "approved",
      "denied",
      "execute",
      "audit_and_execute",
      "executed",
      "execution_failed",
      "rejected",
      "profile_violation",
      "budget_exhausted"
    ]
    |> Enum.reject(&(&1 == current))
  end

  defp terminal_attrs("approved"), do: %{decision: "approved", operator_ref: "operator-1"}

  defp terminal_attrs("denied") do
    %{decision: "denied", operator_ref: "operator-1", denial_reason: "unsafe"}
  end

  defp terminal_attrs(decision) when decision in ["executed", "execution_failed"] do
    %{decision: decision, result_status: "error", result_summary: "terminal update"}
  end

  defp terminal_attrs("profile_violation") do
    %{decision: "profile_violation", result_status: "error", result_summary: ":out_of_scope_tool"}
  end

  defp terminal_attrs("budget_exhausted") do
    %{decision: "budget_exhausted", result_status: "error", result_summary: ":budget_exhausted"}
  end

  defp terminal_attrs(decision), do: %{decision: decision}

  defp approved_decision do
    insert_decision!(
      gate_id: unique("gate"),
      classification: "write_prod_high",
      decision: "gated"
    )
    |> approve_decision!()
  end

  defp approve_decision!(decision) do
    assert {:ok, updated} =
             AuditTrail.update_decision(decision, %{
               decision: "approved",
               operator_ref: "operator-1"
             })

    updated
  end

  defp deny_decision!(decision) do
    assert {:ok, updated} =
             AuditTrail.update_decision(decision, %{
               decision: "denied",
               operator_ref: "operator-1",
               denial_reason: "unsafe"
             })

    updated
  end

  defp execute_decision!(decision) do
    assert {:ok, updated} =
             AuditTrail.update_decision(decision, %{
               decision: "executed",
               result_status: "ok",
               result_summary: "completed"
             })

    updated
  end
end
