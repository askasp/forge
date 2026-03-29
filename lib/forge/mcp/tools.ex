defmodule Forge.MCP.Tools do
  @moduledoc """
  MCP tool definitions for agent supplementary capabilities.
  """

  def definitions do
    [
      %{
        name: "forge_get_project_info",
        description: "Get project conventions, available skills, and test commands.",
        input_schema: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "forge_update_context",
        description:
          "Update persistent project context (architecture, key files, learnings). Used by planner.",
        input_schema: %{
          type: "object",
          properties: %{
            section: %{type: "string", enum: ["architecture", "key_files", "learnings"]},
            content: %{type: "string", description: "New content for the section"}
          },
          required: ["section", "content"]
        }
      },
      %{
        name: "forge_screenshot",
        description:
          "Take a screenshot of a URL using headless Chrome. " <>
            "Starts the project's dev server if needed. " <>
            "Returns the screenshot image URL for embedding in results.",
        input_schema: %{
          type: "object",
          properties: %{
            url: %{type: "string", description: "Full URL to screenshot (e.g. http://localhost:4000/dashboard)"},
            name: %{type: "string", description: "Short descriptive name for the screenshot (e.g. 'login-page')"}
          },
          required: ["url", "name"]
        }
      }
    ]
  end

  @doc "Convert definitions to MCP-compatible JSON map for tools/list response."
  def to_mcp_json do
    tools =
      definitions()
      |> Enum.map(fn tool ->
        %{
          "name" => tool.name,
          "description" => tool.description,
          "inputSchema" => tool.input_schema
        }
      end)

    %{"tools" => tools}
  end
end
