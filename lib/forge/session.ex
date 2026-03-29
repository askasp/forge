defmodule Forge.Session do
  @moduledoc """
  Manages session lifecycle: creation, listing, and cleanup.
  Each session corresponds to a git worktree where agents work.
  State is persisted in Postgres via Ecto.
  """
  require Logger

  alias Forge.Repo
  alias Forge.Schemas.{Project, Session}
  alias Forge.TaskEngine
  import Ecto.Query

  @doc "Create a new session: load project, create worktree, start processes, create planner task."
  def create_session(project_path, goal, opts \\ []) do
    automation = Keyword.get(opts, :automation, :supervised)
    project = Forge.Project.load(project_path)

    session_id_slug = generate_session_id(goal)
    branch = "#{project.branch_prefix}#{session_id_slug}"

    case create_worktree(project_path, branch, project.base_branch) do
      {:ok, worktree_path} ->
        # Find or create project in DB
        db_project = find_or_create_project(project_path, project)

        # Create session in DB
        {:ok, session} =
          %Session{}
          |> Session.changeset(%{
            project_id: db_project.id,
            worktree_path: worktree_path,
            goal: goal,
            automation: automation
          })
          |> Repo.insert()

        # Run install in worktree if package managers are present
        setup_worktree(worktree_path)

        # Start per-session supervisor (Scheduler + AgentSupervisor)
        start_session_processes(session, project)

        # Create initial planner task — Scheduler picks it up via PubSub
        TaskEngine.create_task(session, %{
          role: :planner,
          title: "Plan: #{goal}",
          prompt: goal
        })

        # Remember this project for autocomplete
        Forge.KnownProjects.add(project_path)

        Logger.info("[Session] Created session #{session.id} at #{worktree_path}")
        {:ok, session.id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List all sessions, optionally filtered by state."
  def list_sessions(state_filter \\ nil) do
    task_counts =
      from(t in Forge.Schemas.Task,
        group_by: t.session_id,
        select: %{
          session_id: t.session_id,
          total: count(t.id),
          done: count(fragment("CASE WHEN ? = 'done' THEN 1 END", t.state)),
          failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", t.state)),
          in_progress:
            count(fragment("CASE WHEN ? IN ('assigned', 'in_progress') THEN 1 END", t.state)),
          waiting_human:
            count(
              fragment(
                "CASE WHEN ? IN ('planned', 'assigned') AND ? = 'human' THEN 1 END",
                t.state,
                t.role
              )
            )
        }
      )

    query =
      from(s in Session,
        join: p in Project,
        on: s.project_id == p.id,
        left_join: tc in subquery(task_counts),
        on: tc.session_id == s.id,
        select: %{
          id: s.id,
          goal: s.goal,
          state: s.state,
          automation: s.automation,
          project_name: p.name,
          repo_path: p.repo_path,
          worktree_path: s.worktree_path,
          inserted_at: s.inserted_at,
          total: coalesce(tc.total, 0),
          done: coalesce(tc.done, 0),
          failed: coalesce(tc.failed, 0),
          in_progress: coalesce(tc.in_progress, 0),
          waiting_human: coalesce(tc.waiting_human, 0)
        },
        order_by: [
          desc: coalesce(tc.waiting_human, 0),
          desc: s.inserted_at
        ]
      )

    query =
      if state_filter do
        where(query, [s], s.state == ^state_filter)
      else
        where(query, [s], s.state in [:active, :paused])
      end

    Repo.all(query)
  end

  @doc "Restore active sessions on startup."
  def restore_sessions do
    sessions =
      from(s in Session, where: s.state == :active, preload: [:project])
      |> Repo.all()

    for session <- sessions do
      try do
        if session.worktree_path && File.dir?(session.worktree_path) do
          Logger.info("[Session] Restoring session #{session.id}")

          # Reset orphaned tasks to :planned so they get re-dispatched
          TaskEngine.reset_orphaned_tasks(session.id)

          # Reload project config from disk
          project = Forge.Project.load(session.project.repo_path)

          # Restart session processes
          start_session_processes(session, project)

          Logger.info("[Session] Restored session #{session.id}")
        else
          Logger.info("[Session] Worktree gone for session #{session.id}, marking complete")

          session
          |> Session.changeset(%{state: :complete})
          |> Repo.update()
        end
      rescue
        e ->
          Logger.error(
            "[Session] Failed to restore session #{session.id}: #{Exception.message(e)}"
          )
      end
    end

    Logger.info("[Session] Restore complete: #{length(sessions)} active session(s) found")
  end

  @doc "Stop a running session: terminate supervisor tree, mark paused."
  def stop_session(session_id) do
    terminate_session_processes(session_id)

    case Repo.get(Session, session_id) do
      nil ->
        :ok

      session ->
        session |> Session.changeset(%{state: :paused}) |> Repo.update()
    end

    Logger.info("[Session] Stopped session #{session_id}")
    :ok
  end

  @doc "Push branch to remote and create a GitHub PR via `gh`."
  def create_pr(session_id) do
    session = Repo.get(Session, session_id) |> Repo.preload(:project)

    if session && session.worktree_path && File.dir?(session.worktree_path) do
      project_path = session.project.repo_path
      branch = Path.basename(session.worktree_path)

      # Push branch to remote
      case System.cmd("git", ["push", "-u", "origin", branch],
             cd: project_path,
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          # Create PR with gh CLI
          project = Forge.Project.load(project_path)

          case System.cmd(
                 "gh",
                 [
                   "pr",
                   "create",
                   "--base",
                   project.base_branch,
                   "--head",
                   branch,
                   "--title",
                   session.goal,
                   "--body",
                   "Automated by Forge"
                 ],
                 cd: project_path,
                 stderr_to_stdout: true
               ) do
            {output, 0} ->
              pr_url = output |> String.trim()
              Logger.info("[Session] Created PR: #{pr_url}")
              {:ok, pr_url}

            {output, _} ->
              {:error, "gh pr create failed: #{String.trim(output)}"}
          end

        {output, _} ->
          {:error, "git push failed: #{String.trim(output)}"}
      end
    else
      {:error, "session or worktree not found"}
    end
  end

  @doc "Merge worktree branch into main, delete worktree, mark session complete."
  def merge_into_main(session_id) do
    session = Repo.get(Session, session_id) |> Repo.preload(:project)

    if session && session.worktree_path && File.dir?(session.worktree_path) do
      project_path = session.project.repo_path
      branch = Path.basename(session.worktree_path)
      project = Forge.Project.load(project_path)
      base = project.base_branch

      # Ensure we're on the base branch before merging
      case System.cmd("git", ["checkout", base], cd: project_path, stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, _} ->
          {:error, "checkout #{base} failed: #{String.trim(output)}"}
      end
      |> case do
        :ok ->
          # Merge branch into base
          case System.cmd("git", ["merge", branch, "--no-ff", "-m", "Merge #{branch}"],
                 cd: project_path,
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              # Merge succeeded — clean up in safe order:
              # 1. Delete data (before killing processes to avoid stale PubSub)
              # 2. Update session state
              # 3. Terminate processes last
              task_ids =
                from(t in Forge.Schemas.Task,
                  where: t.session_id == ^session_id,
                  select: t.id
                )

              from(r in Forge.Schemas.AgentRun, where: r.task_id in subquery(task_ids))
              |> Repo.delete_all()

              from(t in Forge.Schemas.Task, where: t.session_id == ^session_id)
              |> Repo.delete_all()

              session |> Session.changeset(%{state: :complete}) |> Repo.update()

              terminate_session_processes(session_id)

              System.cmd("git", ["worktree", "remove", "--force", session.worktree_path],
                cd: project_path,
                stderr_to_stdout: true
              )

              System.cmd("git", ["branch", "-D", branch],
                cd: project_path,
                stderr_to_stdout: true
              )

              Logger.info("[Session] Merged #{branch} into #{base} and cleaned up")
              :ok

            {output, _} ->
              System.cmd("git", ["merge", "--abort"], cd: project_path, stderr_to_stdout: true)
              {:error, "merge failed: #{String.trim(output)}"}
          end

        error ->
          error
      end
    else
      {:error, "session or worktree not found"}
    end
  end

  @doc "Delete a session: stop processes, remove worktree, mark complete."
  def delete_session(session_id) do
    session = Repo.get(Session, session_id) |> Repo.preload(:project)

    if session do
      terminate_session_processes(session_id)

      # Remove worktree
      if session.worktree_path && File.dir?(session.worktree_path) do
        project_path = session.project.repo_path
        branch = Path.basename(session.worktree_path)

        case System.cmd("git", ["worktree", "remove", "--force", session.worktree_path],
               cd: project_path,
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            Logger.info("[Session] Removed worktree #{session.worktree_path}")
            System.cmd("git", ["branch", "-D", branch], cd: project_path, stderr_to_stdout: true)

          {output, _} ->
            Logger.warning("[Session] Failed to remove worktree: #{output}")
            File.rm_rf(session.worktree_path)
        end
      end

      Repo.delete(session)
      Logger.info("[Session] Deleted session #{session_id}")
    end

    :ok
  end

  # ── Private ──────────────────────────────────────────────────────

  @doc "Ensure session processes are running. Restarts them if dead."
  def ensure_running(session_id) do
    if not Forge.Scheduler.alive?(session_id) do
      case Repo.get(Session, session_id) |> Repo.preload(:project) do
        %{state: :active, project: %{repo_path: repo_path}} = session ->
          Logger.warning("[Session] Restarting dead processes for session #{session_id}")
          TaskEngine.reset_orphaned_tasks(session_id)
          project = Forge.Project.load(repo_path)
          start_session_processes(session, project)

        _ ->
          :ok
      end
    end
  end

  defp start_session_processes(session, project) do
    child_spec = {Forge.Session.Supervisor, session: session, project: project}

    case DynamicSupervisor.start_child(Forge.SessionSupervisor, child_spec) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.error("[Session] Failed to start supervisor for #{session.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp terminate_session_processes(session_id) do
    case Registry.lookup(Forge.SessionRegistry, {:session_sup, session_id}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Forge.SessionSupervisor, pid)
      [] -> :ok
    end
  end

  defp find_or_create_project(project_path, project) do
    case Repo.get_by(Project, repo_path: project_path) do
      nil ->
        {:ok, db_project} =
          %Project{}
          |> Project.changeset(%{name: project.name, repo_path: project_path})
          |> Repo.insert()

        db_project

      existing ->
        existing
    end
  end

  defp setup_worktree(worktree_path) do
    parent =
      worktree_path |> String.replace(~r/\.worktrees\/.*$/, "") |> String.trim_trailing("/")

    # Symlink node_modules from parent
    for subdir <- ["", "backend", "frontend", "backoffice"] do
      source = Path.join([parent, subdir, "node_modules"])
      target = Path.join([worktree_path, subdir, "node_modules"])

      if File.dir?(source) and not File.exists?(target) do
        File.ln_s!(source, target)
        Logger.info("[Session] Symlinked #{subdir}/node_modules")
      end
    end

    # Install Elixir deps if mix.exs is present
    if File.exists?(Path.join(worktree_path, "mix.exs")) do
      Logger.info("[Session] Running mix deps.get in worktree")

      System.cmd("mix", ["deps.get"],
        cd: worktree_path,
        stderr_to_stdout: true
      )
    end
  end

  @stop_words ~w(the a an and or but in on at to for of is it we should also with this that from into when have has been be can will)

  defp generate_session_id(goal) do
    slug =
      goal
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.split()
      |> Enum.reject(&(&1 in @stop_words))
      |> Enum.take(6)
      |> Enum.join("-")
      |> String.slice(0, 40)

    suffix = :erlang.system_time(:millisecond) |> rem(10_000) |> to_string()
    "#{slug}-#{suffix}"
  end

  defp create_worktree(project_path, branch, base_branch) do
    worktree_dir = Path.join(project_path, ".worktrees/#{branch}")

    if File.dir?(worktree_dir) do
      Logger.info("[Session] Reusing existing worktree at #{worktree_dir}")
      {:ok, worktree_dir}
    else
      {_, status} =
        System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
          cd: project_path,
          stderr_to_stdout: true
        )

      if status != 0 do
        System.cmd("git", ["branch", branch, base_branch],
          cd: project_path,
          stderr_to_stdout: true
        )
      end

      case System.cmd("git", ["worktree", "add", worktree_dir, branch],
             cd: project_path,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          Logger.info("[Session] Created worktree at #{worktree_dir}")
          {:ok, worktree_dir}

        {output, _} ->
          {:error, "git worktree failed: #{output}"}
      end
    end
  end
end
