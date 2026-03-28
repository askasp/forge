defmodule ForgeWeb.ApiController do
  @moduledoc """
  MCP API for agents. Provides project info and context updates.
  """
  use ForgeWeb, :controller

  alias Forge.Repo
  alias Forge.Schemas.Session

  # Session ID from query param, header, or best-effort match
  defp session_id(conn) do
    conn.params["session_id"] ||
      get_req_header(conn, "x-forge-session") |> List.first() ||
      case Forge.Session.list_sessions() do
        [single] -> single.id
        [_ | _] -> hd(Forge.Session.list_sessions()).id
        [] -> nil
      end
  end

  defp with_session(conn, fun) do
    case session_id(conn) do
      nil ->
        conn |> put_status(404) |> json(%{error: "No active session"})

      id ->
        case Repo.get(Session, id) |> Repo.preload(:project) do
          nil -> conn |> put_status(404) |> json(%{error: "Session not found: #{id}"})
          session -> fun.(session)
        end
    end
  end

  # ── Tool listing ────────────────────────────────────────────────

  def tools(conn, _params) do
    json(conn, Forge.MCP.Tools.to_mcp_json())
  end

  # ── Project info ────────────────────────────────────────────────

  def get_project_info(conn, _params) do
    with_session(conn, fn session ->
      project = Forge.Project.load(session.project.repo_path)

      info = %{
        name: project.name,
        conventions: project.conventions,
        skills: Enum.map(project.skills, fn {name, _} -> name end),
        test_command: project.test_command
      }

      json(conn, info)
    end)
  end

  # ── Project Context ─────────────────────────────────────────────

  def update_context(conn, %{"section" => section, "content" => content})
      when section in ["architecture", "key_files", "learnings"] do
    with_session(conn, fn session ->
      project = Forge.Project.load(session.project.repo_path)

      if project.context do
        case section do
          "learnings" ->
            Forge.ProjectContext.add_learning(project.context, session.id, content)

          _ ->
            Forge.ProjectContext.update_section(project.context, section, content)
        end

        json(conn, %{ok: true})
      else
        conn |> put_status(400) |> json(%{error: "No project context available"})
      end
    end)
  end
end
