defmodule Pageless.Proc.Investigator.Profile do
  @moduledoc "Loads and normalizes YAML-defined investigator profiles."

  @enforce_keys [
    :name,
    :label,
    :prompt_template,
    :tool_scope,
    :output_schema,
    :step_limit,
    :reasoning_visibility
  ]
  defstruct [
    :name,
    :label,
    :prompt_template,
    :tool_scope,
    :output_schema,
    :step_limit,
    :reasoning_visibility
  ]

  @type profile_name :: atom()
  @type tool_scope :: %{
          kubectl: nil | %{verbs: [String.t()] | :all},
          prometheus_query: boolean(),
          query_db: nil | %{tables: [String.t()] | :all},
          mcp_runbook: boolean()
        }
  @type t :: %__MODULE__{
          name: profile_name(),
          label: String.t(),
          prompt_template: String.t(),
          tool_scope: tool_scope(),
          output_schema: map(),
          step_limit: pos_integer(),
          reasoning_visibility: :stream | :batch
        }

  @required_fields ~w(label prompt_template_path tool_scope output_schema step_limit reasoning_visibility)
  @tool_names [:kubectl, :prometheus_query, :query_db, :mcp_runbook]

  @doc "Builds a profile from one investigator_profiles YAML fragment."
  @spec from_yaml(profile_name(), map()) :: {:ok, t()} | {:error, {:invalid_profile, atom()}}
  def from_yaml(name, yaml) when is_atom(name) and is_map(yaml) do
    with :ok <- require_fields(yaml),
         {:ok, prompt_template} <- load_prompt(Map.fetch!(yaml, "prompt_template_path")),
         {:ok, tool_scope} <- normalize_tool_scope(Map.fetch!(yaml, "tool_scope")),
         {:ok, step_limit} <- positive_integer(Map.fetch!(yaml, "step_limit"), :step_limit),
         {:ok, visibility} <- reasoning_visibility(Map.fetch!(yaml, "reasoning_visibility")),
         {:ok, label} <- string_field(Map.fetch!(yaml, "label"), :label),
         {:ok, output_schema} <- map_field(Map.fetch!(yaml, "output_schema"), :output_schema) do
      {:ok,
       %__MODULE__{
         name: name,
         label: label,
         prompt_template: prompt_template,
         tool_scope: tool_scope,
         output_schema: output_schema,
         step_limit: step_limit,
         reasoning_visibility: visibility
       }}
    end
  end

  def from_yaml(_name, _yaml), do: {:error, {:invalid_profile, :profile}}

  @doc "Filters tool modules down to the function declarations allowed by a profile scope."
  @spec build_gemini_function_schema(t(), %{atom() => module()}) :: [map()]
  def build_gemini_function_schema(%__MODULE__{} = profile, tool_modules)
      when is_map(tool_modules) do
    @tool_names
    |> Enum.filter(&enabled?(profile.tool_scope, &1))
    |> Enum.flat_map(fn tool ->
      case Map.fetch(tool_modules, tool) do
        {:ok, module} -> [module.function_call_definition()]
        :error -> []
      end
    end)
  end

  defp require_fields(yaml) do
    case Enum.find(@required_fields, &(not Map.has_key?(yaml, &1))) do
      nil -> :ok
      field -> {:error, {:invalid_profile, String.to_existing_atom(field)}}
    end
  end

  defp load_prompt(path) when is_binary(path) do
    {:ok, File.read!(path)}
  rescue
    _error -> {:error, {:invalid_profile, :prompt_template_path}}
  end

  defp load_prompt(_path), do: {:error, {:invalid_profile, :prompt_template_path}}

  defp normalize_tool_scope(scope) when is_map(scope) do
    {:ok,
     %{
       kubectl: normalize_kubectl(Map.get(scope, "kubectl")),
       prometheus_query: Map.get(scope, "prometheus_query") == true,
       query_db: normalize_query_db(Map.get(scope, "query_db")),
       mcp_runbook: Map.get(scope, "mcp_runbook") == true
     }}
  end

  defp normalize_tool_scope(_scope), do: {:error, {:invalid_profile, :tool_scope}}

  defp normalize_kubectl(nil), do: nil
  defp normalize_kubectl(false), do: nil
  defp normalize_kubectl(%{"verbs" => :all}), do: %{verbs: :all}
  defp normalize_kubectl(%{"verbs" => verbs}) when is_list(verbs), do: %{verbs: verbs}
  defp normalize_kubectl(_scope), do: nil

  defp normalize_query_db(nil), do: nil
  defp normalize_query_db(false), do: nil
  defp normalize_query_db(%{"tables" => :all}), do: %{tables: :all}
  defp normalize_query_db(%{"tables" => tables}) when is_list(tables), do: %{tables: tables}
  defp normalize_query_db(_scope), do: nil

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, field), do: {:error, {:invalid_profile, field}}

  defp reasoning_visibility("stream"), do: {:ok, :stream}
  defp reasoning_visibility("batch"), do: {:ok, :batch}
  defp reasoning_visibility(:stream), do: {:ok, :stream}
  defp reasoning_visibility(:batch), do: {:ok, :batch}
  defp reasoning_visibility(_value), do: {:error, {:invalid_profile, :reasoning_visibility}}

  defp string_field(value, _field) when is_binary(value), do: {:ok, value}
  defp string_field(_value, field), do: {:error, {:invalid_profile, field}}

  defp map_field(value, _field) when is_map(value), do: {:ok, value}
  defp map_field(_value, field), do: {:error, {:invalid_profile, field}}

  defp enabled?(scope, :kubectl), do: not is_nil(scope.kubectl)
  defp enabled?(scope, :prometheus_query), do: scope.prometheus_query == true
  defp enabled?(scope, :query_db), do: not is_nil(scope.query_db)
  defp enabled?(scope, :mcp_runbook), do: scope.mcp_runbook == true
end
