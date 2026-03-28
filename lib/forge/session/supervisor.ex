defmodule Forge.Session.Supervisor do
  @moduledoc """
  Per-session supervisor containing the Scheduler and a DynamicSupervisor
  for AgentRunner processes.
  """
  use Supervisor

  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)

    Supervisor.start_link(__MODULE__, opts,
      name: {:via, Registry, {Forge.SessionRegistry, {:session_sup, session.id}}}
    )
  end

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    project = Keyword.fetch!(opts, :project)

    children = [
      {DynamicSupervisor, name: agent_sup_name(session.id), strategy: :one_for_one},
      {Forge.Scheduler, session: session, project: project}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def agent_sup_name(session_id) do
    {:via, Registry, {Forge.SessionRegistry, {:agent_sup, session_id}}}
  end
end
