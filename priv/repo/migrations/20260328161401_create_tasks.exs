defmodule Forge.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :parent_task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :depends_on_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :role, :string, null: false
      add :state, :string, null: false, default: "planned"
      add :title, :string, null: false
      add :prompt, :text
      add :result, :map
      add :sort_order, :integer, null: false, default: 0
      add :iteration_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:session_id])
    create index(:tasks, [:session_id, :state])
    create index(:tasks, [:depends_on_id])
  end
end
