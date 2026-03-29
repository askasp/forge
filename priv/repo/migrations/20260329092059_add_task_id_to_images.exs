defmodule Forge.Repo.Migrations.AddTaskIdToImages do
  use Ecto.Migration

  def change do
    alter table(:images) do
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:images, [:task_id])
  end
end
