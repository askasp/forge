defmodule Forge.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :worktree_path, :string
      add :goal, :text, null: false
      add :state, :string, null: false, default: "active"
      add :automation, :string, null: false, default: "supervised"

      timestamps(type: :utc_datetime)
    end

    create index(:sessions, [:project_id])
    create index(:sessions, [:state])
  end
end
