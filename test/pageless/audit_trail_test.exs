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

    test "rejects unknown tool name" do
      assert {:error, changeset} = AuditTrail.record_decision(valid_attrs(%{tool: "rm_rf"}))
      assert_changeset_error(changeset, :tool)
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
