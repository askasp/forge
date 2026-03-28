defmodule ForgeWeb.ImageController do
  use ForgeWeb, :controller

  alias Forge.Repo
  alias Forge.Schemas.Image

  def show(conn, %{"id" => id}) do
    case Repo.get(Image, id) do
      %Image{} = image ->
        conn
        |> put_resp_content_type(image.content_type)
        |> send_resp(200, image.data)

      nil ->
        send_resp(conn, 404, "not found")
    end
  end
end
