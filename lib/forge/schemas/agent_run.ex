defmodule Forge.Schemas.AgentRun do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_runs" do
    field :role, Ecto.Enum, values: [:planner, :dev, :qa, :reviewer]
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :exit_code, :integer
    field :stdout_log, :string
    field :structured_output, :map

    belongs_to :task, Forge.Schemas.Task

    timestamps(type: :utc_datetime)
  end

  def changeset(agent_run, attrs) do
    agent_run
    |> cast(attrs, [:task_id, :role, :started_at, :finished_at, :exit_code, :stdout_log, :structured_output])
    |> validate_required([:task_id, :role, :started_at])
    |> foreign_key_constraint(:task_id)
  end
end
