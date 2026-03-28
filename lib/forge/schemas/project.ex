defmodule Forge.Schemas.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :repo_path, :string
    field :pipeline_config, :map, default: %{}

    has_many :sessions, Forge.Schemas.Session

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_path, :pipeline_config])
    |> validate_required([:name, :repo_path])
    |> unique_constraint(:repo_path)
  end
end
