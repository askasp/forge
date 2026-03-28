defmodule Forge.Schemas.ImageTest do
  use ForgeWeb.ConnCase, async: true

  alias Forge.Schemas.{Image, Project, Session}
  alias Forge.Repo

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{name: "test-project", repo_path: "/tmp/test-img-#{System.unique_integer()}"})
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{project_id: project.id, goal: "test goal"})
      |> Repo.insert()

    %{project: project, session: session}
  end

  describe "changeset/2" do
    test "valid changeset with all required fields", %{session: session} do
      attrs = %{
        session_id: session.id,
        filename: "screenshot.png",
        content_type: "image/png",
        data: <<137, 80, 78, 71, 13, 10, 26, 10>>
      }

      changeset = Image.changeset(%Image{}, attrs)
      assert changeset.valid?
    end

    test "invalid changeset missing session_id" do
      attrs = %{
        filename: "screenshot.png",
        content_type: "image/png",
        data: <<137, 80, 78, 71>>
      }

      changeset = Image.changeset(%Image{}, attrs)
      refute changeset.valid?
      assert %{session_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset missing filename", %{session: session} do
      attrs = %{
        session_id: session.id,
        content_type: "image/png",
        data: <<137, 80, 78, 71>>
      }

      changeset = Image.changeset(%Image{}, attrs)
      refute changeset.valid?
      assert %{filename: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset missing content_type", %{session: session} do
      attrs = %{
        session_id: session.id,
        filename: "screenshot.png",
        data: <<137, 80, 78, 71>>
      }

      changeset = Image.changeset(%Image{}, attrs)
      refute changeset.valid?
      assert %{content_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset missing data", %{session: session} do
      attrs = %{
        session_id: session.id,
        filename: "screenshot.png",
        content_type: "image/png"
      }

      changeset = Image.changeset(%Image{}, attrs)
      refute changeset.valid?
      assert %{data: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset with empty attrs" do
      changeset = Image.changeset(%Image{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert %{session_id: ["can't be blank"]} = errors
      assert %{filename: ["can't be blank"]} = errors
      assert %{content_type: ["can't be blank"]} = errors
      assert %{data: ["can't be blank"]} = errors
    end

    test "persists to database with valid attrs", %{session: session} do
      attrs = %{
        session_id: session.id,
        filename: "diagram.jpg",
        content_type: "image/jpeg",
        data: <<255, 216, 255, 224>>
      }

      {:ok, image} = %Image{} |> Image.changeset(attrs) |> Repo.insert()
      assert image.id
      assert image.filename == "diagram.jpg"
      assert image.content_type == "image/jpeg"
      assert image.data == <<255, 216, 255, 224>>
      assert image.session_id == session.id
    end

    test "session association loads via preload", %{session: session} do
      attrs = %{
        session_id: session.id,
        filename: "test.png",
        content_type: "image/png",
        data: <<0, 1, 2, 3>>
      }

      {:ok, image} = %Image{} |> Image.changeset(attrs) |> Repo.insert()
      image = Repo.preload(image, :session)
      assert image.session.id == session.id
      assert image.session.goal == "test goal"
    end

    test "foreign_key_constraint rejects invalid session_id" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        filename: "orphan.png",
        content_type: "image/png",
        data: <<0>>
      }

      assert {:error, changeset} = %Image{} |> Image.changeset(attrs) |> Repo.insert()
      assert %{session_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  # Helper to extract error messages from a changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
