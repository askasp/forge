defmodule Forge.Repo.Migrations.AddPlanMarkdownToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :plan_markdown, :text
    end
  end
end
