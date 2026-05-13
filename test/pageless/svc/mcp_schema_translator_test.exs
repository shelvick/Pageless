defmodule Pageless.Svc.MCPSchemaTranslatorTest do
  @moduledoc "Tests MCP JSON-Schema to Gemini function declaration translation."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Pageless.Svc.MCPClient.Tool
  alias Pageless.Svc.MCPSchemaTranslator

  describe "to_gemini_tools/1 happy paths" do
    test "translates read_file into a Gemini declaration" do
      tool =
        tool("read_file", "Read the contents of a file from disk.", %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Absolute path to read."}
          },
          "required" => ["path"]
        })

      assert MCPSchemaTranslator.to_gemini_tools([tool]) == [
               %{
                 name: "read_file",
                 description: "Read the contents of a file from disk.",
                 parameters: %{
                   "type" => "object",
                   "properties" => %{
                     "path" => %{
                       "type" => "string",
                       "description" => "Absolute path to read."
                     }
                   },
                   "required" => ["path"]
                 }
               }
             ]
    end

    test "preserves list_directory optional path metadata" do
      tool =
        tool("list_directory", "List files in a directory.", %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => []
        })

      assert [gemini_tool] = MCPSchemaTranslator.to_gemini_tools([tool])
      assert gemini_tool.name == "list_directory"
      assert gemini_tool.description == "List files in a directory."
      assert gemini_tool.parameters["properties"] == %{"path" => %{"type" => "string"}}
      assert gemini_tool.parameters["required"] == []
    end

    test "uses an empty Gemini description when MCP description is nil" do
      tool = tool("read_file", nil, object_schema(%{"path" => %{"type" => "string"}}))

      assert [%{description: ""}] = MCPSchemaTranslator.to_gemini_tools([tool])
    end

    test "preserves all supported schema constructs" do
      schema = %{
        "type" => "object",
        "description" => "Runbook search options.",
        "additionalProperties" => false,
        "properties" => %{
          "query" => %{
            "type" => "string",
            "enum" => ["deploy", "rollback"],
            "default" => "deploy",
            "description" => "Search query."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 10,
            "description" => "Maximum matches."
          },
          "score" => %{"type" => "number", "minimum" => 0.0, "maximum" => 1.0},
          "include_archived" => %{"type" => "boolean"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "filters" => %{
            "type" => "object",
            "properties" => %{"service" => %{"type" => "string"}},
            "required" => ["service"]
          }
        },
        "required" => ["query"]
      }

      assert [%{parameters: ^schema}] =
               MCPSchemaTranslator.to_gemini_tools([tool("search_runbooks", "Search.", schema)])
    end

    test "returns an empty list when all tools are dropped" do
      tool = tool("bad", "Bad schema.", %{"type" => "array"})

      assert [] = MCPSchemaTranslator.to_gemini_tools([tool])
    end

    test "preserves input order for translated tools" do
      tools = [
        tool("first", "First.", object_schema(%{})),
        tool("second", "Second.", object_schema(%{})),
        tool("third", "Third.", object_schema(%{}))
      ]

      assert Enum.map(MCPSchemaTranslator.to_gemini_tools(tools), & &1.name) == [
               "first",
               "second",
               "third"
             ]
    end

    test "is pure except warnings from dropped tools" do
      tools = [
        tool("read_file", "Read.", object_schema(%{"path" => %{"type" => "string"}}))
      ]

      first = MCPSchemaTranslator.to_gemini_tools(tools)
      second = MCPSchemaTranslator.to_gemini_tools(tools)

      assert first == second
    end
  end

  describe "to_gemini_tools/1 degradation paths" do
    test "drops nested oneOf schemas and logs the construct" do
      one_of_tool =
        tool("choose_path", "Choose a path.", %{
          "type" => "object",
          "properties" => %{
            "path" => %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
          }
        })

      log = capture_log(fn -> assert [] = MCPSchemaTranslator.to_gemini_tools([one_of_tool]) end)

      assert log =~ "choose_path"
      assert log =~ "oneOf"
    end

    test "drops ref schemas and logs the offending construct" do
      ref_tool = tool("read_ref", "Read.", %{"type" => "object", "$ref" => "#/$defs/input"})

      log = capture_log(fn -> assert [] = MCPSchemaTranslator.to_gemini_tools([ref_tool]) end)

      assert log =~ "read_ref"
      assert log =~ "$ref"
    end

    test "drops non-object top-level schemas and logs non_object_input_schema" do
      array_tool = tool("array_root", "Array root.", %{"type" => "array"})

      log = capture_log(fn -> assert [] = MCPSchemaTranslator.to_gemini_tools([array_tool]) end)

      assert log =~ "array_root"
      assert log =~ "non_object_input_schema"
    end

    test "drops array-form type unions and logs the offending type" do
      union_tool =
        tool("nullable_path", "Nullable path.", %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => ["string", "null"]}}
        })

      log = capture_log(fn -> assert [] = MCPSchemaTranslator.to_gemini_tools([union_tool]) end)

      assert log =~ "nullable_path"
      assert log =~ "type"
    end

    test "drops unknown scalar types and logs the offending type" do
      decimal_tool =
        tool("decimal_tool", "Decimal.", %{
          "type" => "object",
          "properties" => %{"amount" => %{"type" => "decimal"}}
        })

      log = capture_log(fn -> assert [] = MCPSchemaTranslator.to_gemini_tools([decimal_tool]) end)

      assert log =~ "decimal_tool"
      assert log =~ "decimal"
    end

    test "drops every explicitly unsupported construct" do
      unsupported = [
        "anyOf",
        "allOf",
        "not",
        "$defs",
        "pattern",
        "format",
        "if",
        "then",
        "else",
        "dependentSchemas",
        "dependentRequired"
      ]

      for construct <- unsupported do
        schema = %{
          "type" => "object",
          "properties" => %{"path" => Map.put(%{"type" => "string"}, construct, "unsupported")}
        }

        bad_tool = tool("bad_#{construct}", "Bad.", schema)

        log = capture_log(fn -> assert [] = MCPSchemaTranslator.to_gemini_tools([bad_tool]) end)

        assert log =~ "bad_#{construct}"
        assert log =~ construct
      end
    end

    test "returns only clean tools from mixed inputs" do
      tools = [
        tool("read_file", "Read.", object_schema(%{"path" => %{"type" => "string"}})),
        tool("bad_choice", "Bad.", %{
          "type" => "object",
          "properties" => %{"path" => %{"oneOf" => [%{"type" => "string"}]}}
        }),
        tool("list_directory", "List.", object_schema(%{"path" => %{"type" => "string"}}))
      ]

      log =
        capture_log(fn ->
          assert Enum.map(MCPSchemaTranslator.to_gemini_tools(tools), & &1.name) == [
                   "read_file",
                   "list_directory"
                 ]
        end)

      assert log =~ "bad_choice"
      assert log =~ "oneOf"
    end
  end

  describe "translate/1" do
    test "returns {:ok, gemini_tool} for a valid MCP tool without logging" do
      tool = tool("read_file", "Read.", object_schema(%{"path" => %{"type" => "string"}}))

      log =
        capture_log(fn ->
          assert {:ok, %{name: "read_file", description: "Read.", parameters: _parameters}} =
                   MCPSchemaTranslator.translate(tool)
        end)

      assert log == ""
    end

    test "returns a tagged unsupported tuple without logging" do
      tool =
        tool("bad_choice", "Bad.", %{
          "type" => "object",
          "properties" => %{"path" => %{"oneOf" => [%{"type" => "string"}]}}
        })

      log =
        capture_log(fn ->
          assert {:error, {:unsupported, :oneOf, ^tool}} = MCPSchemaTranslator.translate(tool)
        end)

      assert log == ""
    end
  end

  describe "input validation" do
    test "raises ArgumentError when bulk input is not a list of MCP tools" do
      assert_raise ArgumentError, fn -> MCPSchemaTranslator.to_gemini_tools(:not_a_tool_list) end
      assert_raise ArgumentError, fn -> MCPSchemaTranslator.to_gemini_tools([%{}]) end
    end
  end

  defp tool(name, description, input_schema) do
    struct(Tool, name: name, description: description, input_schema: input_schema)
  end

  defp object_schema(properties) do
    %{"type" => "object", "properties" => properties, "required" => Map.keys(properties)}
  end
end
