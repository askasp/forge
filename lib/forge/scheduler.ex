defmodule Forge.Scheduler do
  @moduledoc """
  Per-session scheduler. Subscribes to PubSub, dispatches agents for ready tasks,
  and creates follow-up tasks based on pipeline config.
  """
  use GenServer
  require Logger

  alias Forge.{TaskEngine, Pipeline, PromptBuilder}

  defstruct [
    :session_id,
    :session,
    :project,
    :pipeline,
    automation: :supervised,
    paused: false,
    running: %{},
    cycle_counts: %{},
    max_concurrency: 1
  ]

  # ── Client API ───────────────────────────────────────────────────

  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Forge.SessionRegistry, {:scheduler, session.id}}}
    )
  end

  def pause(session_id) do
    GenServer.cast(via(session_id), :pause)
  end

  def resume(session_id) do
    GenServer.cast(via(session_id), :resume)
  end

  def skip_task(session_id, task_id) do
    GenServer.cast(via(session_id), {:skip_task, task_id})
  end

  def set_automation(session_id, level) do
    GenServer.cast(via(session_id), {:set_automation, level})
  end

  defp via(session_id) do
    {:via, Registry, {Forge.SessionRegistry, {:scheduler, session_id}}}
  end

  # ── Server ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    project = Keyword.fetch!(opts, :project)
    pipeline = Pipeline.load(project.path)

    Phoenix.PubSub.subscribe(Forge.PubSub, "session:#{session.id}")

    state = %__MODULE__{
      session_id: session.id,
      session: session,
      project: project,
      pipeline: pipeline,
      automation: session.automation || :supervised,
      cycle_counts: Pipeline.init_cycle_counts(pipeline)
    }

    # Check for ready tasks on startup (handles restart recovery)
    send(self(), :check_dispatch)

    {:ok, state}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("[Scheduler] Paused session #{state.session_id}")
    broadcast(state.session_id, {:scheduler_paused, state.session_id})
    {:noreply, %{state | paused: true}}
  end

  def handle_cast(:resume, state) do
    Logger.info("[Scheduler] Resumed session #{state.session_id}")
    state = %{state | paused: false}
    broadcast(state.session_id, {:scheduler_resumed, state.session_id})
    {:noreply, maybe_dispatch(state)}
  end

  def handle_cast({:skip_task, task_id}, state) do
    # Kill running agent if this task is active
    state =
      case Map.get(state.running, task_id) do
        {pid, ref} ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
          %{state | running: Map.delete(state.running, task_id)}

        nil ->
          state
      end

    case Forge.Repo.get(Forge.Schemas.Task, task_id) do
      %{state: s} = task when s in [:planned, :assigned, :in_progress] ->
        TaskEngine.transition(task, :done, %{skipped: true})

      _ ->
        :ok
    end

    {:noreply, maybe_dispatch(state)}
  end

  def handle_cast({:set_automation, level}, state) do
    Logger.info("[Scheduler] Automation changed to #{level}")
    {:noreply, %{state | automation: level} |> maybe_dispatch()}
  end

  @impl true
  def handle_info(:check_dispatch, state) do
    {:noreply, maybe_dispatch(state)}
  end

  # PubSub: task created or updated — re-evaluate dispatch
  def handle_info({event, _task}, state) when event in [:task_created, :task_updated, :tasks_created] do
    {:noreply, maybe_dispatch(state)}
  end

  # Direct message from AgentRunner: agent finished
  # IMPORTANT: Process result BEFORE transitioning to :done.
  # This ensures follow-up tasks (QA, review) are created before
  # DashboardLive sees the completion via PubSub broadcast.
  def handle_info({:agent_done, task_id, result}, state) do
    state = remove_running(state, task_id)

    case Forge.Repo.get(Forge.Schemas.Task, task_id) do
      nil ->
        {:noreply, state}

      task ->
        exit_code = Map.get(result, :exit_code, 0)
        structured = Map.get(result, :structured_output)

        if exit_code == 0 do
          # Create follow-up tasks first (before broadcasting :done)
          process_result(task, structured, state)
          # Then transition — this broadcasts :task_updated to LiveView
          TaskEngine.transition(task, :done, structured)
        else
          TaskEngine.fail_task(task, %{exit_code: exit_code, error: Map.get(result, :error)})
        end

        {:noreply, maybe_dispatch(state)}
    end
  end

  # AgentRunner crashed
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case find_task_by_pid(state, pid) do
      {task_id, _} ->
        Logger.error("[Scheduler] Agent crashed for task #{task_id}: #{inspect(reason)}")
        state = remove_running(state, task_id)

        case Forge.Repo.get(Forge.Schemas.Task, task_id) do
          nil -> :ok
          task -> TaskEngine.fail_task(task, %{error: "Agent crashed: #{inspect(reason)}"})
        end

        {:noreply, maybe_dispatch(state)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Dispatch Logic ──────────────────────────────────────────────

  defp maybe_dispatch(%{paused: true} = state), do: state

  defp maybe_dispatch(state) do
    if map_size(state.running) >= state.max_concurrency do
      state
    else
      case TaskEngine.ready_tasks(state.session_id) do
        [] ->
          # Check if session is complete (no running, no ready, no planned)
          if map_size(state.running) == 0, do: check_session_complete(state)
          state

        [task | _] ->
          dispatch_task(task, state)
      end
    end
  end

  defp dispatch_task(%{role: :human} = task, state) do
    case state.automation do
      :autopilot ->
        TaskEngine.transition(task, :done, %{auto_approved: true})
        state

      _ ->
        broadcast(state.session_id, {:waiting_human, task})
        state
    end
  end

  defp dispatch_task(task, state) do
    # Build prompt
    prompt = PromptBuilder.build(state.project, task.role, task.prompt)

    # Transition to assigned
    TaskEngine.transition(task, :assigned)

    # Create agent run record
    {:ok, agent_run} = TaskEngine.create_agent_run(task)

    # Start AgentRunner under the session's AgentSupervisor
    agent_sup = Forge.Session.Supervisor.agent_sup_name(state.session_id)

    {:ok, pid} =
      DynamicSupervisor.start_child(agent_sup, {
        Forge.Session.AgentRunner,
        task: task,
        prompt: prompt,
        scheduler: self(),
        workdir: state.session.worktree_path,
        session_id: state.session_id,
        agent_run_id: agent_run.id
      })

    ref = Process.monitor(pid)
    running = Map.put(state.running, task.id, {pid, ref})

    Logger.info("[Scheduler] Dispatched @#{task.role} for task #{task.id}")
    broadcast(state.session_id, {:agent_started, task.id, task.role})

    %{state | running: running}
  end

  # ── Pipeline Follow-Up Logic ───────────────────────────────────

  defp process_result(task, result, state) do
    case task.role do
      :planner ->
        process_planner_result(result, state)

      role ->
        stage = Pipeline.stage_for_role(state.pipeline, role)
        if stage, do: process_stage_result(task, result, stage, state)
    end
  end

  defp process_planner_result(result, state) do
    tasks =
      case result do
        %{"tasks" => tasks} when is_list(tasks) ->
          Enum.map(tasks, fn t ->
            %{
              role: :dev,
              title: t["title"] || "Untitled task",
              prompt: t["prompt"] || "",
              acceptance_criteria: t["acceptance_criteria"],
              depends_on: t["depends_on"]
            }
          end)

        _ ->
          Logger.warning("[Scheduler] Planner output not parseable: #{inspect(result)}")
          []
      end

    if tasks != [] do
      session = Forge.Repo.get!(Forge.Schemas.Session, state.session_id)
      TaskEngine.create_tasks(session, tasks)
    end
  end

  defp process_stage_result(task, result, stage, state) do
    passed = result_passed?(task.role, result)

    cond do
      not passed and stage.on_failure == :fix_cycle ->
        create_fix_cycle_tasks(task, result, stage, state)

      passed and is_binary(stage.on_success) ->
        # Success → create next stage's task
        case Pipeline.stage_by_id(state.pipeline, stage.on_success) do
          nil ->
            :ok

          next_stage ->
            session = Forge.Repo.get!(Forge.Schemas.Session, state.session_id)

            TaskEngine.create_task(session, %{
              role: next_stage.role,
              title: "#{next_stage.role}: #{task.title}",
              prompt: build_followup_prompt(next_stage.role, task, result, state),
              parent_task_id: task.id,
              depends_on_id: task.id
            })
        end

      true ->
        :ok
    end
  end

  defp create_fix_cycle_tasks(task, result, stage, state) do
    role_key = task.role
    current_count = Map.get(state.cycle_counts, role_key, 0)

    if current_count >= stage.max_cycles do
      Logger.warning("[Scheduler] Max fix cycles (#{stage.max_cycles}) reached for #{role_key}")
      broadcast(state.session_id, {:cycle_limit_reached, task.id, role_key})
    else
      session = Forge.Repo.get!(Forge.Schemas.Session, state.session_id)
      issues = Map.get(result || %{}, "issues", [])
      issues_text = Enum.join(issues, "\n- ")

      # Find the original dev task's acceptance criteria (trace via parent)
      criteria = find_acceptance_criteria(task)
      criteria_text = if criteria, do: "\n\nAcceptance criteria to meet:\n#{criteria}", else: ""

      # Create fix task for the fix_role (usually :dev)
      {:ok, fix_task} =
        TaskEngine.create_task(session, %{
          role: stage.fix_role,
          title: "Fix: #{task.title}",
          prompt: "Fix the issues found by #{role_key}:\n- #{issues_text}\n\nOriginal task: #{task.prompt}#{criteria_text}",
          acceptance_criteria: criteria,
          parent_task_id: task.id,
          depends_on_id: task.id
        })

      # Create re-run task for the checking role
      TaskEngine.create_task(session, %{
        role: task.role,
        title: "Re-check: #{task.title}",
        prompt: build_followup_prompt(task.role, fix_task, nil, state),
        parent_task_id: task.id,
        depends_on_id: fix_task.id
      })

      # Update cycle count (in-memory only, resets on restart)
      # This is fine since cycles are per-session
    end
  end

  defp result_passed?(role, result) when role in [:qa, :reviewer] do
    case result do
      %{"passed" => true} -> true
      _ -> false
    end
  end

  defp result_passed?(_role, _result), do: true

  defp build_followup_prompt(role, parent_task, result, _state) do
    context =
      case result do
        nil -> ""
        %{"result" => summary} -> "\n\nPrevious agent result: #{summary}"
        %{"files_changed" => files} -> "\n\nFiles changed: #{Enum.join(files, ", ")}"
        _ -> "\n\nPrevious result: #{inspect(result)}"
      end

    criteria = find_acceptance_criteria(parent_task)

    criteria_section =
      if criteria do
        "\n\nAcceptance criteria to verify:\n#{criteria}"
      else
        ""
      end

    base_prompt = "Review the changes from task: #{parent_task.title}#{context}#{criteria_section}"

    case role do
      :qa -> "#{base_prompt}\n\nRun tests and verify the implementation meets the acceptance criteria."
      :reviewer -> "#{base_prompt}\n\nReview the code for quality, security, and correctness."
      _ -> base_prompt
    end
  end

  defp find_acceptance_criteria(task) do
    cond do
      task.acceptance_criteria && task.acceptance_criteria != "" ->
        task.acceptance_criteria

      task.parent_task_id ->
        case Forge.Repo.get(Forge.Schemas.Task, task.parent_task_id) do
          nil -> nil
          parent -> find_acceptance_criteria(parent)
        end

      true ->
        nil
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp remove_running(state, task_id) do
    case Map.pop(state.running, task_id) do
      {{_pid, ref}, running} ->
        Process.demonitor(ref, [:flush])
        %{state | running: running}

      {nil, _} ->
        state
    end
  end

  defp find_task_by_pid(state, pid) do
    Enum.find(state.running, fn {_task_id, {p, _ref}} -> p == pid end)
  end

  defp check_session_complete(state) do
    {done, total} = TaskEngine.progress(state.session_id)

    if done == total and total > 0 do
      broadcast(state.session_id, {:session_complete, state.session_id})
    end
  end

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Forge.PubSub, "session:#{session_id}", event)
  end
end
