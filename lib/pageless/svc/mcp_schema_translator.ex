defmodule Pageless.Svc.MCPSchemaTranslator do
  @moduledoc "Translates MCP JSON-Schema tool descriptors into Gemini function declarations."

  require Logger

  alias Pageless.Svc.MCPClient.Tool

  @type gemini_tool :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:parameters) => map()
        }

  @type translation_outcome ::
          {:ok, gemini_tool()} | {:error, {:unsupported, atom() | String.t(), Tool.t()}}

  @unsupported_keys [
    "oneOf",
    "anyOf",
    "allOf",
    "not",
    "$ref",
    "$defs",
    "pattern",
    "format",
    "if",
    "then",
    "else",
    "dependentSchemas",
    "dependentRequired"
  ]

  @supported_scalar_types ["string", "integer", "number", "boolean"]

  @doc "Translates MCP tools into Gemini function declarations, dropping unsupported tools."
  @spec to_gemini_tools([Tool.t()] | term()) :: [gemini_tool()]
  def to_gemini_tools(tools) do
    if is_list(tools) and Enum.all?(tools, &match?(%Tool{}, &1)) do
      Enum.flat_map(tools, &translate_or_log/1)
    else
      raise ArgumentError, "expected a list of MCP tool structs"
    end
  end

  @doc "Translates one MCP tool and reports unsupported schemas without logging."
  @spec translate(Tool.t()) :: translation_outcome()
  def translate(%Tool{} = tool) do
    with {:ok, schema} <- translate_root(tool.input_schema, tool) do
      {:ok, %{name: tool.name, description: tool.description || "", parameters: schema}}
    end
  end

  @spec translate_or_log(Tool.t()) :: [gemini_tool()]
  defp translate_or_log(tool) do
    case translate(tool) do
      {:ok, gemini_tool} ->
        [gemini_tool]

      {:error, {:unsupported, reason, failed_tool}} ->
        Logger.warning("dropping MCP tool #{failed_tool.name}: unsupported #{reason}")
        []
    end
  end

  @spec translate_root(term(), Tool.t()) ::
          {:ok, map()} | {:error, {:unsupported, atom() | String.t(), Tool.t()}}
  defp translate_root(%{"type" => "object"} = schema, tool), do: translate_schema(schema, tool)
  defp translate_root(_schema, tool), do: {:error, {:unsupported, :non_object_input_schema, tool}}

  @spec translate_schema(term(), Tool.t()) ::
          {:ok, map()} | {:error, {:unsupported, atom() | String.t(), Tool.t()}}
  defp translate_schema(schema, tool) when is_map(schema) do
    with :ok <- reject_unsupported_keys(schema, tool),
         {:ok, type} <- schema_type(schema, tool) do
      translate_by_type(type, schema, tool)
    end
  end

  defp translate_schema(_schema, tool), do: {:error, {:unsupported, :invalid_schema, tool}}

  @spec translate_by_type(String.t(), map(), Tool.t()) ::
          {:ok, map()} | {:error, {:unsupported, atom() | String.t(), Tool.t()}}
  defp translate_by_type("object", schema, tool) do
    with {:ok, properties} <- translate_properties(Map.get(schema, "properties", %{}), tool) do
      {:ok, Map.put(schema, "properties", properties)}
    end
  end

  defp translate_by_type("array", %{"items" => items} = schema, tool) do
    with {:ok, translated_items} <- translate_schema(items, tool) do
      {:ok, Map.put(schema, "items", translated_items)}
    end
  end

  defp translate_by_type("array", _schema, tool),
    do: {:error, {:unsupported, :array_without_items, tool}}

  defp translate_by_type(type, schema, _tool) when type in @supported_scalar_types,
    do: {:ok, schema}

  defp translate_by_type(type, _schema, tool), do: {:error, {:unsupported, type, tool}}

  @spec translate_properties(term(), Tool.t()) ::
          {:ok, map()} | {:error, {:unsupported, atom() | String.t(), Tool.t()}}
  defp translate_properties(properties, tool) when is_map(properties) do
    Enum.reduce_while(properties, {:ok, %{}}, fn {name, property_schema}, {:ok, acc} ->
      case translate_schema(property_schema, tool) do
        {:ok, translated} -> {:cont, {:ok, Map.put(acc, name, translated)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp translate_properties(_properties, tool),
    do: {:error, {:unsupported, :invalid_properties, tool}}

  @spec reject_unsupported_keys(map(), Tool.t()) ::
          :ok | {:error, {:unsupported, atom() | String.t(), Tool.t()}}
  defp reject_unsupported_keys(schema, tool) do
    case Enum.find(@unsupported_keys, &Map.has_key?(schema, &1)) do
      nil -> :ok
      key -> {:error, {:unsupported, unsupported_reason(key), tool}}
    end
  end

  @spec schema_type(map(), Tool.t()) ::
          {:ok, String.t()} | {:error, {:unsupported, atom() | String.t(), Tool.t()}}
  defp schema_type(%{"type" => type}, tool) when is_list(type),
    do: {:error, {:unsupported, :type, tool}}

  defp schema_type(%{"type" => type}, _tool) when is_binary(type), do: {:ok, type}
  defp schema_type(_schema, tool), do: {:error, {:unsupported, :missing_type, tool}}

  @spec unsupported_reason(String.t()) :: atom() | String.t()
  defp unsupported_reason("oneOf"), do: :oneOf
  defp unsupported_reason("anyOf"), do: :anyOf
  defp unsupported_reason("allOf"), do: :allOf
  defp unsupported_reason(key), do: key
end
