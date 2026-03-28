defmodule Forge.TaskEngine do
  @moduledoc """
  Context module for task and agent run operations.
  Every mutation broadcasts via PubSub on "session:<session_id>".
  """

  alias Forge.Repo
  alias Forge.Schemas.{Task, AgentRun}
  import Ecto.Query

  # ── Task CRUD ──────────────────────────────────────────────────

  @doc "Create a single task for a session. Broadcasts {:task_created, task}."
  def create_task(%{id: session_id} = _session, attrs) do
    sort_order = next_sort_order(session_id)

    %Task{}
    |> Task.changeset(Map.merge(attrs, %{session_id: session_id, sort_order: sort_order}))
    |> Repo.insert()
    |> broadcast(session_id, :task_created)
  end

  @doc "Create multiple tasks at once. Broadcasts {:tasks_created, tasks}."
  def create_tasks(%{id: session_id} = _session, list_of_attrs) do
    base_order = next_sort_order(session_id)

    # First pass: insert all tasks and build an index map (position -> task_id)
    # for resolving depends_on references
    {tasks, _} =
      list_of_attrs
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {attrs, idx}, {acc, id_map} ->
        # Resolve depends_on from positional index to actual task ID
        depends_on_id =
          case Map.get(attrs, :depends_on) do
            nil -> nil
            pos when is_integer(pos) -> Map.get(id_map, pos)
            _ -> nil
          end

        task_attrs =
          attrs
          |> Map.drop([:depends_on])
          |> Map.merge(%{
            session_id: session_id,
            sort_order: base_order + idx,
            depends_on_id: depends_on_id
          })

        case Repo.insert(Task.changeset(%Task{}, task_attrs)) do
          {:ok, task} ->
            {[task | acc], Map.put(id_map, idx, task.id)}

          {:error, _changeset} ->
            {acc, id_map}
        end
      end)

    tasks = Enum.reverse(tasks)
    broadcast_event(session_id, {:tasks_created, tasks})
    {:ok, tasks}
  end

  @doc "Transition a task to a new state, optionally setting result."
  def transition(%Task{} = task, new_state, result \\ nil) do
    task
    |> Task.transition_changeset(new_state, result)
    |> Repo.update()
    |> broadcast(task.session_id, :task_updated)
  end

  @doc "Transition a task to :failed and increment iteration_count."
  def fail_task(%Task{} = task, error_info \\ nil) do
    task
    |> Task.transition_changeset(:failed, error_info)
    |> Ecto.Changeset.put_change(:iteration_count, task.iteration_count + 1)
    |> Repo.update()
    |> broadcast(task.session_id, :task_updated)
  end

  @doc "Reset a failed task back to :planned for retry."
  def retry_task(%Task{} = task) do
    transition(task, :planned)
  end

  # ── Queries ────────────────────────────────────────────────────

  @doc """
  Find tasks that are ready to be dispatched:
  state is :planned AND (no dependency OR dependency is :done).
  """
  def ready_tasks(session_id) do
    from(t in Task,
      left_join: dep in Task,
      on: t.depends_on_id == dep.id,
      where: t.session_id == ^session_id,
      where: t.state == :planned,
      where: is_nil(t.depends_on_id) or dep.state == :done,
      order_by: t.sort_order
    )
    |> Repo.all()
  end

  @doc "List all tasks for a session, ordered by sort_order."
  def list_tasks(session_id) do
    from(t in Task,
      where: t.session_id == ^session_id,
      order_by: t.sort_order,
      preload: [:agent_runs]
    )
    |> Repo.all()
  end

  @doc "Get a single task by ID."
  def get_task!(id), do: Repo.get!(Task, id) |> Repo.preload(:agent_runs)

  @doc "Return {done_count, total_count} for a session."
  def progress(session_id) do
    from(t in Task, where: t.session_id == ^session_id)
    |> Repo.all()
    |> Enum.reduce({0, 0}, fn task, {done, total} ->
      if task.state == :done, do: {done + 1, total + 1}, else: {done, total + 1}
    end)
  end

  @doc "Delete all planned tasks for a session (used for re-planning)."
  def delete_planned_tasks(session_id) do
    from(t in Task,
      where: t.session_id == ^session_id,
      where: t.state == :planned
    )
    |> Repo.delete_all()
  end

  @doc "Check if a task already has a follow-up task with the given role."
  def has_followup_task?(task_id, role) do
    from(t in Task,
      where: t.depends_on_id == ^task_id,
      where: t.role == ^role,
      where: t.state != :failed
    )
    |> Repo.exists?()
  end

  @doc "Reparent planned tasks: move depends_on from old task to new task."
  def reparent_dependents(old_task_id, new_task_id) do
    from(t in Task,
      where: t.depends_on_id == ^old_task_id,
      where: t.state == :planned
    )
    |> Repo.update_all(set: [depends_on_id: new_task_id])
  end

  @doc "Fail any in_progress tasks for a session (used on restart to clean up orphans)."
  def fail_orphaned_tasks(session_id) do
    from(t in Task,
      where: t.session_id == ^session_id,
      where: t.state in [:assigned, :in_progress]
    )
    |> Repo.update_all(set: [state: :failed])
  end

  # ── Agent Runs ─────────────────────────────────────────────────

  @doc "Create an agent run record when an agent starts."
  def create_agent_run(%Task{} = task, attrs \\ %{}) do
    %AgentRun{}
    |> AgentRun.changeset(
      Map.merge(attrs, %{
        task_id: task.id,
        role: task.role,
        started_at: DateTime.utc_now()
      })
    )
    |> Repo.insert()
  end

  @doc "Complete an agent run with exit info."
  def complete_agent_run(%AgentRun{} = run, attrs) do
    run
    |> AgentRun.changeset(Map.put(attrs, :finished_at, DateTime.utc_now()))
    |> Repo.update()
  end

  def complete_agent_run(run_id, attrs) when is_binary(run_id) do
    Repo.get!(AgentRun, run_id)
    |> complete_agent_run(attrs)
  end

  # ── Private ────────────────────────────────────────────────────

  defp next_sort_order(session_id) do
    from(t in Task,
      where: t.session_id == ^session_id,
      select: max(t.sort_order)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      max -> max + 1
    end
  end

  defp broadcast({:ok, record} = result, session_id, event) do
    broadcast_event(session_id, {event, record})
    result
  end

  defp broadcast({:error, _} = result, _session_id, _event), do: result

  defp broadcast_event(session_id, event) do
    Phoenix.PubSub.broadcast(Forge.PubSub, "session:#{session_id}", event)
  end
end
