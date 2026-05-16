defmodule Pageless.Svc.GeminiClient do
  @moduledoc "Adapter that normalizes Gemini responses for Pageless agents."

  @behaviour Pageless.Svc.GeminiClient.Behaviour

  alias Pageless.Svc.GeminiClient.Behaviour
  alias Pageless.Svc.GeminiClient.Chunk
  alias Pageless.Svc.GeminiClient.FunctionCall
  alias Pageless.Svc.GeminiClient.Response

  @type gemini_response :: map()

  @doc "Generates a non-streaming Gemini response."
  @impl Behaviour
  @spec generate(Behaviour.generate_opts()) :: {:ok, Response.t()} | {:error, term()}
  def generate(opts) do
    with :ok <- claim_budget(opts) do
      generate_after_budget_claim(opts)
    end
  end

  defp generate_after_budget_claim(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    model = opts |> Keyword.get(:model, :flash) |> model_name()
    metadata = Keyword.get(opts, :metadata, %{})

    :telemetry.execute(
      [:pageless, :gemini, :generate, :start],
      %{prompt_size: prompt_size(prompt), tool_count: tool_count(opts)},
      %{model: model, metadata: metadata}
    )

    gemini_module = Keyword.get(opts, :gemini_module, Gemini)

    case gemini_module.generate_content(prompt, gemini_opts(opts, model)) do
      {:ok, response} ->
        parsed = parse_response(response)

        :telemetry.execute(
          [:pageless, :gemini, :generate, :stop],
          %{},
          %{model: model, metadata: metadata}
        )

        {:ok, parsed}

      {:error, reason} ->
        :telemetry.execute(
          [:pageless, :gemini, :generate, :exception],
          %{},
          %{model: model, metadata: metadata, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc "Starts a Gemini stream and forwards mailbox envelopes to the caller."
  @impl Behaviour
  @spec start_stream(Behaviour.stream_opts()) :: {:ok, reference()} | {:error, term()}
  def start_stream(opts) do
    with :ok <- claim_budget(opts) do
      start_stream_after_budget_claim(opts)
    end
  end

  defp start_stream_after_budget_claim(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    caller = Keyword.get(opts, :caller, self())
    ref = make_ref()
    model = opts |> Keyword.get(:model, :flash) |> model_name()
    metadata = Keyword.get(opts, :metadata, %{})
    gemini_module = Keyword.get(opts, :gemini_module, Gemini)
    stream_opts = gemini_opts(opts, model)

    :telemetry.execute(
      [:pageless, :gemini, :stream, :start],
      %{prompt_size: prompt_size(prompt), tool_count: tool_count(opts)},
      %{ref: ref, model: model, metadata: metadata}
    )

    stream_context = %{caller: caller, ref: ref, model: model, metadata: metadata}

    {:ok, _pid} =
      Task.start_link(fn ->
        translate_stream(gemini_module, prompt, stream_opts, stream_context)
      end)

    {:ok, ref}
  end

  @type stream_context :: %{
          caller: pid(),
          ref: reference(),
          model: String.t(),
          metadata: map()
        }

  @spec claim_budget(keyword()) :: :ok | {:error, :budget_exhausted}
  defp claim_budget(opts) do
    opts
    |> Keyword.get(:budget, Pageless.GeminiBudget)
    |> Pageless.GeminiBudget.increment()
  end

  @spec translate_stream(module(), String.t() | [map()], keyword(), stream_context()) :: :ok
  defp translate_stream(gemini_module, prompt, opts, context) do
    case gemini_module.stream_generate(prompt, opts) do
      {:ok, stream_id} ->
        :ok = gemini_module.subscribe_stream(stream_id)
        receive_stream(stream_id, context)

      {:error, reason} ->
        send(context.caller, {:gemini_error, context.ref, reason})

        :telemetry.execute(
          [:pageless, :gemini, :stream, :exception],
          %{},
          %{ref: context.ref, model: context.model, metadata: context.metadata, reason: reason}
        )
    end

    :ok
  end

  @spec receive_stream(term(), stream_context()) :: :ok
  defp receive_stream(stream_id, context) do
    receive do
      {:stream_event, ^stream_id, {:error, reason}} ->
        send(context.caller, {:gemini_error, context.ref, reason})

        :telemetry.execute(
          [:pageless, :gemini, :stream, :exception],
          %{},
          %{ref: context.ref, model: context.model, metadata: context.metadata, reason: reason}
        )

      {:stream_event, ^stream_id, event} ->
        event
        |> chunks_from_event(context.ref)
        |> Enum.each(fn chunk ->
          send(context.caller, {:gemini_chunk, context.ref, chunk})

          :telemetry.execute(
            [:pageless, :gemini, :stream, :chunk],
            %{chunk_type: chunk.type},
            %{ref: context.ref, model: context.model, metadata: context.metadata}
          )
        end)

        if terminal_event?(event) do
          final = %{finish_reason: finish_reason(event), usage: usage(event)}
          send(context.caller, {:gemini_done, context.ref, final})

          :telemetry.execute(
            [:pageless, :gemini, :stream, :done],
            %{},
            %{ref: context.ref, model: context.model, metadata: context.metadata}
          )
        else
          receive_stream(stream_id, context)
        end
    end
  end

  @spec parse_response(gemini_response()) :: Response.t()
  defp parse_response(response) do
    %Response{
      text: response |> text_parts() |> Enum.join(""),
      function_calls: function_calls(response),
      finish_reason: finish_reason(response),
      usage: usage(response),
      raw: response
    }
  end

  @spec chunks_from_event(gemini_response(), reference()) :: [Chunk.t()]
  defp chunks_from_event(event, ref) do
    text_chunks =
      event
      |> text_parts()
      |> Enum.map(&%Chunk{type: :text, text: &1, ref: ref})

    function_chunks =
      event
      |> function_calls()
      |> Enum.map(&%Chunk{type: :function_call, function_call: &1, ref: ref})

    text_chunks ++ function_chunks
  end

  @spec text_parts(gemini_response()) :: [String.t()]
  defp text_parts(response) do
    response
    |> parts()
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      _part -> []
    end)
  end

  @spec function_calls(gemini_response()) :: [FunctionCall.t()]
  defp function_calls(response) do
    response
    |> parts()
    |> Enum.flat_map(fn
      %{"functionCall" => call} -> [function_call(call)]
      %{functionCall: call} -> [function_call(call)]
      _part -> []
    end)
  end

  @spec function_call(map()) :: FunctionCall.t()
  defp function_call(call) do
    %FunctionCall{
      name: Map.get(call, "name") || Map.get(call, :name),
      args: Map.get(call, "args") || Map.get(call, :args) || %{},
      id: Map.get(call, "id") || Map.get(call, :id)
    }
  end

  @spec parts(gemini_response()) :: [map()]
  defp parts(response) do
    response
    |> candidates()
    |> Enum.flat_map(fn candidate ->
      candidate
      |> content()
      |> Map.get("parts", Map.get(content(candidate), :parts, []))
    end)
  end

  @spec candidates(gemini_response()) :: [map()]
  defp candidates(response) do
    Map.get(response, "candidates") || Map.get(response, :candidates) || []
  end

  @spec content(map()) :: map()
  defp content(candidate) do
    Map.get(candidate, "content") || Map.get(candidate, :content) || %{}
  end

  @spec finish_reason(gemini_response()) :: Response.finish_reason()
  defp finish_reason(response) do
    response
    |> candidates()
    |> Enum.find_value(fn candidate ->
      Map.get(candidate, "finishReason") || Map.get(candidate, :finishReason) ||
        Map.get(candidate, :finish_reason)
    end)
    |> normalize_finish_reason()
  end

  @spec terminal_event?(gemini_response()) :: boolean()
  defp terminal_event?(event), do: finish_reason(event) != :other or usage(event) != nil

  @spec normalize_finish_reason(nil | atom() | String.t()) :: Response.finish_reason()
  defp normalize_finish_reason(nil), do: :other
  defp normalize_finish_reason(:stop), do: :stop
  defp normalize_finish_reason(:max_tokens), do: :max_tokens
  defp normalize_finish_reason(:safety), do: :safety
  defp normalize_finish_reason(:recitation), do: :recitation
  defp normalize_finish_reason(:tool_calls), do: :tool_calls

  defp normalize_finish_reason(reason) when is_binary(reason) do
    case String.upcase(reason) do
      "STOP" -> :stop
      "MAX_TOKENS" -> :max_tokens
      "SAFETY" -> :safety
      "RECITATION" -> :recitation
      "TOOL_CALLS" -> :tool_calls
      _other -> :other
    end
  end

  defp normalize_finish_reason(_reason), do: :other

  @spec usage(gemini_response()) :: Response.usage() | nil
  defp usage(response) do
    case Map.get(response, "usageMetadata") || Map.get(response, :usageMetadata) ||
           Map.get(response, :usage_metadata) do
      nil ->
        nil

      usage ->
        %{
          prompt_tokens: Map.get(usage, "promptTokenCount") || Map.get(usage, :promptTokenCount),
          completion_tokens:
            Map.get(usage, "candidatesTokenCount") || Map.get(usage, :candidatesTokenCount),
          total_tokens: Map.get(usage, "totalTokenCount") || Map.get(usage, :totalTokenCount)
        }
    end
  end

  @spec gemini_opts(keyword(), String.t()) :: keyword()
  defp gemini_opts(opts, model) do
    opts
    |> Keyword.take([:api_key, :system_instruction, :tools, :tool_choice, :safety_settings])
    |> Keyword.put(:model, model)
    |> maybe_put_generation_config(opts)
  end

  @spec maybe_put_generation_config(keyword(), keyword()) :: keyword()
  defp maybe_put_generation_config(gemini_opts, opts) do
    generation_config = Keyword.get(opts, :generation_config, %{}) || %{}

    generation_config =
      case Keyword.fetch(opts, :temperature) do
        {:ok, temperature} -> Map.put(generation_config, :temperature, temperature)
        :error -> generation_config
      end

    if map_size(generation_config) == 0 do
      gemini_opts
    else
      Keyword.put(gemini_opts, :generation_config, generation_config)
    end
  end

  @spec model_name(Behaviour.model()) :: String.t()
  defp model_name(:flash), do: "gemini-2.5-flash"
  defp model_name(:pro), do: "gemini-2.5-pro"
  defp model_name(model) when is_binary(model), do: model

  @spec prompt_size(String.t() | [map()] | term()) :: non_neg_integer()
  defp prompt_size(prompt) when is_binary(prompt), do: String.length(prompt)
  defp prompt_size(prompt) when is_list(prompt), do: length(prompt)
  defp prompt_size(_prompt), do: 0

  @spec tool_count(keyword()) :: non_neg_integer()
  defp tool_count(opts), do: opts |> Keyword.get(:tools, []) |> length()
end
