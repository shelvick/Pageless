defmodule Pageless.Svc.GeminiClient.Behaviour do
  @moduledoc "Behaviour for injectable Gemini client implementations in agent tests."

  alias Pageless.Svc.GeminiClient.Response

  @type model :: :flash | :pro | String.t()
  @type tool_choice :: :auto | :any | {:specific, String.t()} | :none

  @type generate_opts :: [
          prompt: String.t() | [map()],
          model: model(),
          system_instruction: String.t() | nil,
          temperature: float() | nil,
          tools: [map()] | nil,
          tool_choice: tool_choice() | nil,
          generation_config: map() | nil,
          safety_settings: [map()] | nil,
          api_key: String.t() | nil,
          metadata: map() | nil,
          gemini_module: module() | nil
        ]

  @type stream_opts :: [
          prompt: String.t() | [map()],
          model: model(),
          system_instruction: String.t() | nil,
          temperature: float() | nil,
          tools: [map()] | nil,
          tool_choice: tool_choice() | nil,
          generation_config: map() | nil,
          safety_settings: [map()] | nil,
          api_key: String.t() | nil,
          metadata: map() | nil,
          gemini_module: module() | nil,
          caller: pid() | nil
        ]

  @doc "Generates a single Gemini response."
  @callback generate(generate_opts()) :: {:ok, Response.t()} | {:error, term()}

  @doc "Starts a streaming Gemini response and returns its correlation ref."
  @callback start_stream(stream_opts()) :: {:ok, reference()} | {:error, term()}
end
