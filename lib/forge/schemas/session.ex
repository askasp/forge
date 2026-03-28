defmodule Forge.Schemas.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field(:worktree_path, :string)
    field(:goal, :string)
    field(:state, Ecto.Enum, values: [:active, :paused, :complete], default: :active)

    field(:automation, Ecto.Enum,
      values: [:manual, :supervised, :autopilot],
      default: :supervised
    )

    belongs_to(:project, Forge.Schemas.Project)
    has_many(:tasks, Forge.Schemas.Task)

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:project_id, :worktree_path, :goal, :state, :automation])
    |> validate_required([:project_id, :goal])
    |> foreign_key_constraint(:project_id)
  end
end
