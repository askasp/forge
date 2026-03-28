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
