defmodule Pageless.Svc.GeminiClientTest.BudgetBlockedGemini do
  @moduledoc "Gemini double that fails the test if budget exhaustion does not short-circuit."

  @doc "Raises when a budget-exhausted path still dispatches a non-streaming call."
  @spec generate_content(String.t(), keyword()) :: no_return()
  def generate_content(_prompt, _opts), do: raise("Gemini dispatch should be budget-blocked")

  @doc "Raises when a budget-exhausted path still dispatches a streaming call."
  @spec stream_generate(String.t(), keyword()) :: no_return()
  def stream_generate(_prompt, _opts), do: raise("Gemini stream should be budget-blocked")
end

defmodule Pageless.Svc.GeminiClientTest.FakeGemini do
  @moduledoc "Deterministic Gemini-shaped test double for adapter tests."

  @doc "Returns canned Gemini generate responses for adapter tests."
  @spec generate_content(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_content(prompt, opts) do
    if Keyword.get(opts, :api_key) == "invalid-key" do
      {:error, {:http_error, 401}}
    else
      generate_success(prompt)
    end
  end

  defp generate_success("Pick the next safe action") do
    {:ok,
     %{
       "candidates" => [
         %{
           "content" => %{
             "parts" => [
               %{"text" => "I should call restart_pod."},
               %{
                 "functionCall" => %{
                   "name" => "restart_pod",
                   "args" => %{"pod" => "api-7"},
                   "id" => "call-1"
                 }
               }
             ]
           },
           "finishReason" => "TOOL_CALLS"
         }
       ],
       "usageMetadata" => %{
         "promptTokenCount" => 7,
         "candidatesTokenCount" => 4,
         "totalTokenCount" => 11
       }
     }}
  end

  defp generate_success("Say OK") do
    {:ok,
     %{
       "candidates" => [
         %{
           "content" => %{"parts" => [%{"text" => "OK"}]},
           "finishReason" => "STOP"
         }
       ]
     }}
  end

  defp generate_success(_prompt) do
    {:ok,
     %{
       "candidates" => [
         %{
           "content" => %{"parts" => [%{"text" => "hello"}]},
           "finishReason" => "STOP"
         }
       ]
     }}
  end

  @doc "Returns a deterministic fake stream id for adapter tests."
  @spec stream_generate(String.t(), keyword()) :: {:ok, term()}
  def stream_generate(prompt, _opts), do: {:ok, {:fake_stream, prompt}}

  @doc "Sends canned stream events to the current process."
  @spec subscribe_stream(term()) :: :ok
  def subscribe_stream({:fake_stream, "stream with bad key"} = stream_id) do
    send(self(), {:stream_event, stream_id, {:error, {:http_error, 401}}})
    :ok
  end

  def subscribe_stream({:fake_stream, "choose a remediation function"} = stream_id) do
    send(self(), {:stream_event, stream_id, function_call_event()})
    send(self(), {:stream_event, stream_id, done_event("TOOL_CALLS")})
    :ok
  end

  def subscribe_stream({:fake_stream, prompt} = stream_id)
      when prompt in ["stream A", "stream B"] do
    send(self(), {:stream_event, stream_id, text_event(prompt)})
    send(self(), {:stream_event, stream_id, done_event("STOP")})
    :ok
  end

  def subscribe_stream({:fake_stream, _prompt} = stream_id) do
    send(self(), {:stream_event, stream_id, text_event("streamed text")})
    send(self(), {:stream_event, stream_id, done_event("STOP")})
    :ok
  end

  defp text_event(text) do
    %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text}]}}]}
  end

  defp function_call_event do
    %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [
              %{
                "functionCall" => %{
                  "name" => "restart_pod",
                  "args" => %{"pod" => "api-7"},
                  "id" => "call-1"
                }
              }
            ]
          }
        }
      ]
    }
  end

  defp done_event(reason) do
    %{
      "candidates" => [%{"finishReason" => reason}],
      "usageMetadata" => %{
        "promptTokenCount" => 2,
        "candidatesTokenCount" => 3,
        "totalTokenCount" => 5
      }
    }
  end
end

defmodule Pageless.Svc.GeminiClientTest do
  @moduledoc "Tests the Gemini client adapter contract and mailbox envelopes."
  use ExUnit.Case, async: true

  import Hammox

  alias Pageless.Svc.GeminiClient
  alias Pageless.Svc.GeminiClient.Behaviour
  alias Pageless.Svc.GeminiClient.Chunk
  alias Pageless.Svc.GeminiClient.FunctionCall
  alias Pageless.Svc.GeminiClient.Response
  alias Pageless.Svc.GeminiClientTest.BudgetBlockedGemini
  alias Pageless.Svc.GeminiClientTest.FakeGemini

  setup :verify_on_exit!

  describe "behaviour and structs" do
    test "behaviour exposes only generate/1 and start_stream/1 callbacks" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert Enum.sort(callbacks) == [generate: 1, start_stream: 1]
    end

    test "response, chunk, and function call structs define the contract" do
      ref = make_ref()

      function_call =
        struct(FunctionCall, name: "restart_pod", args: %{"pod" => "api-7"}, id: "call-1")

      chunk = struct(Chunk, type: :function_call, function_call: function_call, ref: ref)

      response =
        struct(Response,
          text: "inspect first",
          function_calls: [function_call],
          finish_reason: :tool_calls
        )

      assert function_call.name == "restart_pod"
      assert function_call.args == %{"pod" => "api-7"}
      assert chunk.ref == ref
      assert chunk.type == :function_call
      assert response.function_calls == [function_call]
    end

    test "Hammox mock sends synthetic stream envelopes" do
      caller = self()
      ref = make_ref()

      Pageless.Svc.GeminiClient.Mock
      |> stub(:start_stream, fn opts ->
        assert Keyword.fetch!(opts, :caller) == caller

        send(
          caller,
          {:gemini_chunk, ref, struct(Chunk, type: :text, text: "synthetic", ref: ref)}
        )

        send(caller, {:gemini_done, ref, %{finish_reason: :stop, usage: nil}})
        {:ok, ref}
      end)

      alias Pageless.Svc.GeminiClient.Mock

      assert {:ok, ^ref} =
               Mock.start_stream(
                 prompt: "hi",
                 model: :flash,
                 caller: caller
               )

      assert_receive {:gemini_chunk, ^ref, chunk}
      assert chunk.__struct__ == Chunk
      assert chunk.type == :text
      assert chunk.text == "synthetic"
      assert chunk.ref == ref
      assert_receive {:gemini_done, ^ref, %{finish_reason: :stop, usage: nil}}
    end
  end

  describe "generate/1" do
    test "returns function-call descriptors without auto-executing tools" do
      assert {:ok, response} =
               GeminiClient.generate(
                 prompt: "Pick the next safe action",
                 model: :pro,
                 temperature: 0.0,
                 tools: [restart_pod_tool()],
                 tool_choice: {:specific, "restart_pod"},
                 api_key: "test-key",
                 gemini_module: FakeGemini
               )

      assert response.__struct__ == Response
      assert response.text == "I should call restart_pod."
      assert response.finish_reason == :tool_calls

      assert response.function_calls == [
               struct(FunctionCall, name: "restart_pod", args: %{"pod" => "api-7"}, id: "call-1")
             ]
    end

    test "returns an empty list when no function calls are emitted" do
      assert {:ok, response} =
               GeminiClient.generate(
                 prompt: "Say OK",
                 model: :flash,
                 tool_choice: :none,
                 tools: [restart_pod_tool()],
                 api_key: "test-key",
                 gemini_module: FakeGemini
               )

      assert response.__struct__ == Response
      assert response.text == "OK"
      assert response.function_calls == []
      assert response.finish_reason == :stop
    end

    test "returns error tuples instead of raising for upstream errors" do
      assert {:error, {:http_error, 401}} =
               GeminiClient.generate(
                 prompt: "hello",
                 model: :flash,
                 api_key: "invalid-key",
                 gemini_module: FakeGemini
               )
    end

    test "emits generate start and stop telemetry with call metadata" do
      test_pid = self()
      handler_id = {:test_gemini_telemetry, System.unique_integer([:positive])}
      events = [[:pageless, :gemini, :generate, :start], [:pageless, :gemini, :generate, :stop]]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, response} =
               GeminiClient.generate(
                 prompt: "hello",
                 model: :flash,
                 tools: [%{name: "noop"}],
                 metadata: %{alert_id: "alert-123"},
                 api_key: "test-key",
                 gemini_module: FakeGemini
               )

      assert response.__struct__ == Response

      assert_receive {:telemetry_event, [:pageless, :gemini, :generate, :start],
                      start_measurements, start_metadata}

      assert start_measurements.prompt_size == 5
      assert start_measurements.tool_count == 1
      assert start_metadata.model == "gemini-2.5-flash"
      assert start_metadata.metadata == %{alert_id: "alert-123"}

      assert_receive {:telemetry_event, [:pageless, :gemini, :generate, :stop],
                      _stop_measurements, stop_metadata}

      assert stop_metadata.model == "gemini-2.5-flash"
    end

    test "returns budget exhaustion without dispatching to Gemini" do
      budget =
        start_supervised!({Pageless.GeminiBudget, cap: 0, clock: fixed_clock(~D[2026-05-15])})

      assert {:error, :budget_exhausted} =
               GeminiClient.generate(
                 prompt: "Say OK",
                 model: :flash,
                 api_key: "test-key",
                 budget: budget,
                 gemini_module: BudgetBlockedGemini
               )
    end
  end

  describe "start_stream/1" do
    test "sends text chunks and one done envelope to the default caller" do
      assert {:ok, ref} =
               GeminiClient.start_stream(
                 prompt: "stream a short answer",
                 model: :flash,
                 api_key: "test-key",
                 gemini_module: FakeGemini
               )

      assert is_reference(ref)
      assert_receive {:gemini_chunk, ^ref, chunk}
      assert chunk.__struct__ == Chunk
      assert chunk.type == :text
      assert is_binary(chunk.text)
      assert chunk.ref == ref
      assert_receive {:gemini_done, ^ref, %{finish_reason: :stop, usage: _usage}}
      refute_receive {:gemini_error, ^ref, _reason}
      refute_receive {:gemini_done, ^ref, _duplicate}
    end

    test "routes stream envelopes to the explicit caller pid" do
      parent = self()

      receiver_task =
        Task.async(fn ->
          receive do
            {:begin, owner} ->
              {:ok, ref} =
                GeminiClient.start_stream(
                  prompt: "route this",
                  model: :flash,
                  caller: self(),
                  api_key: "test-key",
                  gemini_module: FakeGemini
                )

              send(owner, {:stream_started, ref})

              receive do
                {:gemini_chunk, ^ref, chunk} -> send(owner, {:receiver_chunk, ref, chunk})
              end

              receive do
                {:gemini_done, ^ref, final} ->
                  send(owner, {:receiver_done, ref, final})
                  :ok

                {:gemini_error, ^ref, reason} ->
                  send(owner, {:receiver_error, ref, reason})
                  :ok
              end
          end
        end)

      send(receiver_task.pid, {:begin, parent})

      assert_receive {:stream_started, ref}
      assert_receive {:receiver_chunk, ^ref, chunk}
      assert chunk.__struct__ == Chunk
      assert chunk.ref == ref
      assert_receive {:receiver_done, ^ref, %{finish_reason: :stop}}
      refute_receive {:gemini_chunk, ^ref, _chunk}
      assert :ok = Task.await(receiver_task, 1_000)
    end

    test "keeps concurrent stream chunks correlated by their own refs" do
      assert {:ok, ref_a} =
               GeminiClient.start_stream(
                 prompt: "stream A",
                 model: :flash,
                 api_key: "test-key",
                 gemini_module: FakeGemini
               )

      assert {:ok, ref_b} =
               GeminiClient.start_stream(
                 prompt: "stream B",
                 model: :flash,
                 api_key: "test-key",
                 gemini_module: FakeGemini
               )

      assert ref_a != ref_b

      {stream_a_messages, stream_b_messages} =
        collect_stream_messages([ref_a, ref_b], %{ref_a => [], ref_b => []})

      assert Enum.any?(stream_a_messages, &chunk_for_ref?(&1, ref_a))
      assert Enum.any?(stream_b_messages, &chunk_for_ref?(&1, ref_b))
      refute Enum.any?(stream_a_messages, &chunk_for_ref?(&1, ref_b))
      refute Enum.any?(stream_b_messages, &chunk_for_ref?(&1, ref_a))
    end

    test "forwards streamed function calls and continues through done" do
      assert {:ok, ref} =
               GeminiClient.start_stream(
                 prompt: "choose a remediation function",
                 model: :pro,
                 tools: [restart_pod_tool()],
                 tool_choice: :any,
                 api_key: "test-key",
                 gemini_module: FakeGemini
               )

      assert_receive {:gemini_chunk, ^ref, chunk}
      assert chunk.__struct__ == Chunk
      assert chunk.type == :function_call
      assert chunk.ref == ref
      assert chunk.function_call.__struct__ == FunctionCall
      assert chunk.function_call.name == "restart_pod"
      assert chunk.function_call.args == %{"pod" => "api-7"}

      assert_receive {:gemini_done, ^ref, %{finish_reason: :tool_calls}}
    end

    test "propagates stream failures as error envelopes" do
      assert {:ok, ref} =
               GeminiClient.start_stream(
                 prompt: "stream with bad key",
                 model: :flash,
                 api_key: "invalid-key",
                 gemini_module: FakeGemini
               )

      assert_receive {:gemini_error, ^ref, {:http_error, 401}}
      refute_receive {:gemini_done, ^ref, _final}
    end

    test "emits stream start, chunk, and done telemetry" do
      test_pid = self()
      handler_id = {:test_gemini_telemetry, System.unique_integer([:positive])}

      events = [
        [:pageless, :gemini, :stream, :start],
        [:pageless, :gemini, :stream, :chunk],
        [:pageless, :gemini, :stream, :done]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, ref} =
               GeminiClient.start_stream(
                 prompt: "stream telemetry",
                 model: :flash,
                 metadata: %{agent_id: "triager-1"},
                 api_key: "test-key",
                 gemini_module: FakeGemini
               )

      assert_receive {:gemini_chunk, ^ref, chunk}
      assert chunk.__struct__ == Chunk
      assert_receive {:gemini_done, ^ref, _final}

      assert_receive {:telemetry_event, [:pageless, :gemini, :stream, :start],
                      _start_measurements, start_metadata}

      assert start_metadata.ref == ref
      assert start_metadata.metadata == %{agent_id: "triager-1"}

      assert_receive {:telemetry_event, [:pageless, :gemini, :stream, :chunk], chunk_measurements,
                      chunk_metadata}

      assert chunk_measurements.chunk_type in [:text, :function_call]
      assert chunk_metadata.ref == ref

      assert_receive {:telemetry_event, [:pageless, :gemini, :stream, :done], _done_measurements,
                      done_metadata}

      assert done_metadata.ref == ref
    end

    test "returns budget exhaustion synchronously without starting a stream" do
      budget =
        start_supervised!({Pageless.GeminiBudget, cap: 0, clock: fixed_clock(~D[2026-05-15])})

      assert {:error, :budget_exhausted} =
               GeminiClient.start_stream(
                 prompt: "stream a short answer",
                 model: :flash,
                 caller: self(),
                 api_key: "test-key",
                 budget: budget,
                 gemini_module: BudgetBlockedGemini
               )

      refute_receive {:gemini_chunk, _ref, _chunk}
      refute_receive {:gemini_done, _ref, _final}
      refute_receive {:gemini_error, _ref, _reason}
    end
  end

  defp collect_stream_messages(ref, acc) when is_reference(ref) do
    receive do
      {:gemini_done, ^ref, _final} = message -> Enum.reverse([message | acc])
      {:gemini_error, ^ref, _reason} = message -> Enum.reverse([message | acc])
      {:gemini_chunk, ^ref, _chunk} = message -> collect_stream_messages(ref, [message | acc])
      _other -> collect_stream_messages(ref, acc)
    after
      1_000 -> Enum.reverse(acc)
    end
  end

  defp collect_stream_messages([ref_a, ref_b] = refs, streams) do
    if terminal_count(streams) == length(refs) do
      {Enum.reverse(Map.fetch!(streams, ref_a)), Enum.reverse(Map.fetch!(streams, ref_b))}
    else
      receive do
        {:gemini_done, ref, _final} = message ->
          collect_stream_message(refs, streams, ref, message)

        {:gemini_error, ref, _reason} = message ->
          collect_stream_message(refs, streams, ref, message)

        {:gemini_chunk, ref, _chunk} = message ->
          collect_stream_message(refs, streams, ref, message)

        _other ->
          collect_stream_messages(refs, streams)
      after
        1_000 ->
          {Enum.reverse(Map.fetch!(streams, ref_a)), Enum.reverse(Map.fetch!(streams, ref_b))}
      end
    end
  end

  defp collect_stream_message(refs, streams, ref, message) do
    if ref in refs do
      collect_stream_messages(refs, Map.update!(streams, ref, &[message | &1]))
    else
      collect_stream_messages(refs, streams)
    end
  end

  defp terminal_count(streams) do
    Enum.count(streams, fn {_ref, messages} ->
      Enum.any?(messages, fn
        {:gemini_done, _ref, _final} -> true
        {:gemini_error, _ref, _reason} -> true
        _message -> false
      end)
    end)
  end

  defp chunk_for_ref?({:gemini_chunk, ref, %{__struct__: Chunk, ref: ref}}, ref), do: true
  defp chunk_for_ref?(_message, _ref), do: false

  defp fixed_clock(date), do: fn -> date end

  defp restart_pod_tool do
    %{
      name: "restart_pod",
      description: "restart one pod",
      parameters: %{
        type: "object",
        properties: %{pod: %{type: "string"}},
        required: ["pod"]
      }
    }
  end
end
