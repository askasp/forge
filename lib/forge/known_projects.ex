defmodule Forge.KnownProjects do
  @moduledoc """
  Persists known project paths to ~/.forge/projects.json.
  Used for autocomplete on the home page.
  """

  @dir Path.expand("~/.forge")
  @path Path.join(@dir, "projects.json")

  def list do
    case File.read(@path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, projects} when is_list(projects) ->
            Enum.filter(projects, &valid_project?/1)

          _ ->
            []
        end

      {:error, _} ->
        []
    end
  end

  def add(project_path) do
    projects = list()

    unless project_path in projects do
      updated = [project_path | projects] |> Enum.take(50)
      save(updated)
    end
  end

  def remove(project_path) do
    projects = list() |> Enum.reject(&(&1 == project_path))
    save(projects)
  end

  defp valid_project?(path) do
    not String.starts_with?(path, "/tmp") and File.dir?(path)
  end

  defp save(projects) do
    File.mkdir_p!(@dir)
    File.write!(@path, Jason.encode!(projects, pretty: true))
  end
end
