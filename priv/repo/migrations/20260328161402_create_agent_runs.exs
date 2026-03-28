defmodule Forge.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :exit_code, :integer
      add :stdout_log, :text
      add :structured_output, :map

      timestamps(type: :utc_datetime)
    end

    create index(:agent_runs, [:task_id])
  end
end
