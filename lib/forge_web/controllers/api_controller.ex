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

  # ── Screenshot ─────────────────────────────────────────────────

  def screenshot(conn, %{"url" => url, "name" => name}) do
    with_session(conn, fn session ->
      project = Forge.Project.load(session.project.repo_path)

      with :ok <- maybe_start_dev_server(session, project),
           :ok <- maybe_wait_for_server(session.id, project),
           {:ok, png_data} <- Forge.Screenshot.capture(url) do
        task_id = get_req_header(conn, "x-forge-task") |> List.first()
        filename = "#{name}-#{System.system_time(:second)}.png"

        {:ok, image} =
          %Forge.Schemas.Image{}
          |> Forge.Schemas.Image.changeset(%{
            session_id: session.id,
            task_id: task_id,
            filename: filename,
            content_type: "image/png",
            data: png_data
          })
          |> Repo.insert()

        json(conn, %{ok: true, image_url: "/images/#{image.id}", filename: filename})
      else
        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: "Screenshot failed: #{reason}"})
      end
    end)
  end

  defp maybe_start_dev_server(session, project) do
    if project.dev_start && !Forge.DevServer.running?(session.id) do
      case DynamicSupervisor.start_child(
             Forge.Session.Supervisor.agent_sup_name(session.id),
             {Forge.DevServer,
              session_id: session.id,
              workdir: session.worktree_path,
              dev_start: project.dev_start}
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> {:error, "Failed to start dev server: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  defp maybe_wait_for_server(session_id, project) do
    if project.screenshot_url do
      Forge.DevServer.ensure_ready(session_id, project.screenshot_url)
    else
      :ok
    end
  end
end
