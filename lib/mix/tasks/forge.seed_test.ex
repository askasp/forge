defmodule Mix.Tasks.Forge.SeedTest do
  @moduledoc """
  Run an end-to-end smoke test: create a session, watch it plan, execute, and complete.

  Usage: mix forge.seed_test [project_path]

  Defaults to the current directory. Creates a simple goal (health check endpoint),
  auto-resumes on plan pause, and monitors until completion or timeout.
  """
  use Mix.Task
  require Logger

  @timeout_ms 10 * 60 * 1000

  def run(args) do
    Mix.Task.run("app.start")

    project_path = List.first(args) || File.cwd!()

    goal =
      "Add a health check endpoint: GET /api/health that returns JSON " <>
        ~s({"status": "ok", "timestamp": "<iso8601>"}. Add a test for this endpoint.)

    IO.puts("Creating session for: #{project_path}")
    IO.puts("Goal: #{String.trim(goal)}")
    IO.puts("---")

    case Forge.Session.create_session(project_path, goal) do
      {:ok, session} ->
        IO.puts("Session created: #{session.id}")
        IO.puts("Worktree: #{session.worktree_path}")
        Phoenix.PubSub.subscribe(Forge.PubSub, "session:#{session.id}")
        monitor_loop(session.id, System.monotonic_time(:millisecond))

      {:error, reason} ->
        IO.puts("Failed to create session: #{inspect(reason)}")
    end
  end

  defp monitor_loop(session_id, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > @timeout_ms do
      IO.puts("\nTIMEOUT — session did not complete in #{div(@timeout_ms, 60_000)} minutes")
      print_summary(session_id, :timeout)
      return()
    end

    receive do
      {:task_updated, task} ->
        IO.puts("[#{format_state(task.state)}] @#{task.role} — #{task.title}")
        monitor_loop(session_id, start_time)

      {:task_created, task} ->
        IO.puts("[new] @#{task.role} — #{task.title}")
        monitor_loop(session_id, start_time)

      {:agent_started, _task_id, role} ->
        IO.puts("  >> @#{role} agent started")
        monitor_loop(session_id, start_time)

      {:agent_finished, _task_id, role} ->
        IO.puts("  << @#{role} agent finished")
        {done, total} = Forge.TaskEngine.progress(session_id)
        IO.puts("  Progress: #{done}/#{total}")
        monitor_loop(session_id, start_time)

      {:scheduler_paused, _} ->
        IO.puts("\nPlan review pause — auto-resuming...")
        Process.sleep(1000)
        Forge.Scheduler.resume(session_id)
        monitor_loop(session_id, start_time)

      {:session_complete, _} ->
        IO.puts("\nSESSION COMPLETE!")
        print_summary(session_id, :complete)

      {:cycle_limit_reached, _task_id, role} ->
        IO.puts("\nCYCLE LIMIT for @#{role} — skipping")
        monitor_loop(session_id, start_time)

      _other ->
        monitor_loop(session_id, start_time)
    after
      30_000 ->
        # Check if session is still alive every 30s
        {done, total} = Forge.TaskEngine.progress(session_id)
        IO.puts("  ... waiting (#{done}/#{total})")
        monitor_loop(session_id, start_time)
    end
  end

  defp print_summary(session_id, status) do
    tasks = Forge.TaskEngine.list_tasks(session_id)
    done = Enum.count(tasks, &(&1.state == :done))
    failed = Enum.filter(tasks, &(&1.state == :failed))
    planned = Enum.count(tasks, &(&1.state == :planned))

    IO.puts("\n=== SUMMARY ===")
    IO.puts("Status: #{status}")
    IO.puts("Tasks: #{length(tasks)} total, #{done} done, #{length(failed)} failed, #{planned} planned")

    if failed != [] do
      IO.puts("\nFailed tasks:")

      for t <- failed do
        IO.puts("  - @#{t.role} #{t.title}")
        if t.result, do: IO.puts("    #{inspect(t.result)}")
      end
    end

    if status == :complete and failed == [] do
      IO.puts("\nSUCCESS — all tasks completed without failures")
    end
  end

  defp format_state(:planned), do: "    "
  defp format_state(:assigned), do: " >> "
  defp format_state(:in_progress), do: " .. "
  defp format_state(:done), do: " OK "
  defp format_state(:failed), do: "FAIL"
  defp format_state(s), do: " #{s} "

  defp return, do: :ok
end
