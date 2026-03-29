defmodule Forge.Schemas.Image do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "images" do
    field :filename, :string
    field :content_type, :string
    field :data, :binary

    belongs_to :session, Forge.Schemas.Session
    belongs_to :task, Forge.Schemas.Task

    timestamps(type: :utc_datetime)
  end

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:session_id, :task_id, :filename, :content_type, :data])
    |> validate_required([:session_id, :filename, :content_type, :data])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:task_id)
  end
end
