defmodule Forge.FileTree do
  @moduledoc "Lists project files for @ mention autocomplete."

  @ignored_dirs ~w(.git node_modules _build deps .elixir_ls .forge priv/static vendor dist __pycache__ .next .cache target)

  @doc """
  List files in a project directory up to max_depth levels deep.
  Returns a sorted list of relative paths (e.g., ["lib/forge/session.ex", "lib/forge_web/live/home_live.ex"]).
  Skips common ignored directories.
  """
  def list(project_path, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 4)
    max_files = Keyword.get(opts, :max_files, 5000)

    project_path
    |> collect_files("", 0, max_depth, max_files)
    |> Enum.sort()
  end

  @doc """
  Search files matching a query string. Returns up to `limit` results.
  Matches against the full relative path (case-insensitive).
  Prioritizes basename matches over full path matches.
  """
  def search(project_path, query, files \\ nil, limit \\ 15) do
    all_files = files || list(project_path)
    query_down = String.downcase(query)

    {basename_matches, path_matches} =
      all_files
      |> Enum.filter(&String.contains?(String.downcase(&1), query_down))
      |> Enum.split_with(fn path ->
        String.contains?(String.downcase(Path.basename(path)), query_down)
      end)

    (basename_matches ++ path_matches)
    |> Enum.take(limit)
  end

  defp collect_files(_path, _rel, depth, max_depth, _max_files) when depth > max_depth, do: []

  defp collect_files(path, rel, depth, max_depth, max_files) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&ignored?/1)
        |> Enum.sort()
        |> Enum.flat_map_reduce(0, fn entry, count ->
          if count >= max_files do
            {[], count}
          else
            full = Path.join(path, entry)
            relative = if rel == "", do: entry, else: Path.join(rel, entry)

            if File.dir?(full) do
              children = collect_files(full, relative, depth + 1, max_depth, max_files - count)
              {children, count + length(children)}
            else
              {[relative], count + 1}
            end
          end
        end)
        |> elem(0)

      {:error, _} ->
        []
    end
  end

  defp ignored?(entry), do: entry in @ignored_dirs or String.starts_with?(entry, ".")
end
