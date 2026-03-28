defmodule Forge.SchedulerTest do
  use ForgeWeb.ConnCase, async: false

  alias Forge.Repo
  alias Forge.Schemas.{Session, Task}
  alias Forge.Scheduler

  setup do
    db_project =
      %Forge.Schemas.Project{}
      |> Forge.Schemas.Project.changeset(%{name: "sched-test", repo_path: "/tmp/sched-test"})
      |> Repo.insert!()

    session =
      %Session{}
      |> Session.changeset(%{
        project_id: db_project.id,
        goal: "Scheduler test goal",
        worktree_path: "/tmp/sched-test-wt",
        automation: :supervised
      })
      |> Repo.insert!()

    # The Scheduler expects a %Forge.Project{} config struct (not the Ecto schema)
    project = %Forge.Project{path: "/tmp/sched-test", name: "sched-test"}

    %{project: project, session: session}
  end

  describe "set_automation/2 does not dispatch" do
    test "setting autopilot does not auto-approve a planned human task", %{
      session: session,
      project: project
    } do
      # Create a human task in :planned state (ready, no dependency)
      {:ok, task} =
        Forge.TaskEngine.create_task(session, %{
          role: :human,
          title: "Approve changes",
          prompt: "Please review and approve"
        })

      assert task.state == :planned

      # Start the scheduler directly
      {:ok, pid} =
        Scheduler.start_link(session: session, project: project)

      # Wait for the initial :check_dispatch to run — in supervised mode,
      # human tasks get transitioned to :assigned (waiting for human).
      Process.sleep(50)

      # The task should have been moved to :assigned by the initial dispatch
      task_after_init = Repo.get!(Task, task.id)
      assert task_after_init.state == :assigned

      # Now set automation to autopilot
      Scheduler.set_automation(session.id, :autopilot)

      # Give it time to process the cast
      Process.sleep(50)

      # Verify the scheduler's internal state was updated
      scheduler_state = :sys.get_state(pid)
      assert scheduler_state.automation == :autopilot

      # The task should still be :assigned — NOT transitioned to :done
      # This is the core assertion: set_automation must NOT trigger dispatch
      task_after_set = Repo.get!(Task, task.id)
      assert task_after_set.state == :assigned
    end

    test "set_automation updates internal automation level", %{
      session: session,
      project: project
    } do
      {:ok, pid} =
        Scheduler.start_link(session: session, project: project)

      # Initial state should be :supervised (from session)
      state = :sys.get_state(pid)
      assert state.automation == :supervised

      # Set to autopilot
      Scheduler.set_automation(session.id, :autopilot)
      Process.sleep(20)
      assert :sys.get_state(pid).automation == :autopilot

      # Set to manual
      Scheduler.set_automation(session.id, :manual)
      Process.sleep(20)
      assert :sys.get_state(pid).automation == :manual

      # Set back to supervised
      Scheduler.set_automation(session.id, :supervised)
      Process.sleep(20)
      assert :sys.get_state(pid).automation == :supervised
    end
  end
end
