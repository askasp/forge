defmodule ForgeWeb.ImageControllerTest do
  use ForgeWeb.ConnCase, async: true

  alias Forge.Schemas.{Image, Project, Session}
  alias Forge.Repo

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{name: "img-ctrl-project", repo_path: "/tmp/ctrl-#{System.unique_integer()}"})
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{project_id: project.id, goal: "controller test"})
      |> Repo.insert()

    %{session: session}
  end

  describe "GET /images/:id" do
    test "returns 200 with correct content-type for a PNG image", %{conn: conn, session: session} do
      png_data = <<137, 80, 78, 71, 13, 10, 26, 10>>

      {:ok, image} =
        %Image{}
        |> Image.changeset(%{
          session_id: session.id,
          filename: "screenshot.png",
          content_type: "image/png",
          data: png_data
        })
        |> Repo.insert()

      conn = get(conn, ~p"/images/#{image.id}")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
      assert conn.resp_body == png_data
    end

    test "returns 200 with correct content-type for a JPEG image", %{conn: conn, session: session} do
      jpeg_data = <<255, 216, 255, 224, 0, 16>>

      {:ok, image} =
        %Image{}
        |> Image.changeset(%{
          session_id: session.id,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          data: jpeg_data
        })
        |> Repo.insert()

      conn = get(conn, ~p"/images/#{image.id}")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
      assert conn.resp_body == jpeg_data
    end

    test "returns 404 for non-existent image ID", %{conn: conn} do
      non_existent_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/images/#{non_existent_id}")
      assert conn.status == 404
      assert conn.resp_body == "not found"
    end

    test "raises on invalid UUID format", %{conn: conn} do
      # Repo.get with a non-UUID string raises Ecto.Query.CastError
      assert_raise Ecto.Query.CastError, fn ->
        get(conn, "/images/not-a-uuid")
      end
    end
  end
end
