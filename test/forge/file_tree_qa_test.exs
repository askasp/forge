defmodule Forge.FileTreeQATest do
  @moduledoc "QA tests for FileTree acceptance criteria."
  use ExUnit.Case, async: true

  alias Forge.FileTree

  setup do
    tmp = Path.join(System.tmp_dir!(), "file_tree_qa_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  # ── AC: list/2 returns relative file paths ─────────────────────────

  describe "list/2 returns relative paths" do
    test "paths are relative (no leading slash or absolute prefix)", %{tmp: tmp} do
      File.mkdir_p!(Path.join([tmp, "lib", "forge"]))
      File.write!(Path.join([tmp, "lib", "forge", "session.ex"]), "")
      File.write!(Path.join(tmp, "mix.exs"), "")

      result = FileTree.list(tmp)

      for path <- result do
        refute String.starts_with?(path, "/"),
               "Expected relative path but got: #{path}"

        refute String.starts_with?(path, tmp),
               "Path should not contain the project root: #{path}"
      end

      assert "lib/forge/session.ex" in result
      assert "mix.exs" in result
    end

    test "deeply nested files use forward-slash separated relative paths", %{tmp: tmp} do
      File.mkdir_p!(Path.join([tmp, "a", "b", "c"]))
      File.write!(Path.join([tmp, "a", "b", "c", "deep.ex"]), "")

      result = FileTree.list(tmp)

      assert "a/b/c/deep.ex" in result
    end
  end

  # ── AC: Hidden directories and common ignored dirs are excluded ────

  describe "hidden and ignored directories excluded" do
    test "single-component ignored directories are excluded", %{tmp: tmp} do
      # These are all single-component names that match ignored?/1 directly
      ignored = ~w(.git node_modules _build deps .elixir_ls .forge vendor dist __pycache__ .next .cache target)

      for dir <- ignored do
        full = Path.join(tmp, dir)
        File.mkdir_p!(full)
        File.write!(Path.join(full, "file.txt"), "content")
      end

      File.write!(Path.join(tmp, "visible.ex"), "")

      result = FileTree.list(tmp)

      assert result == ["visible.ex"]
    end

    test "BUG: priv/static in @ignored_dirs never matches (path vs entry name)", %{tmp: tmp} do
      # priv/static is listed in @ignored_dirs but ignored?/1 compares against
      # individual directory names ("priv", "static"), not full paths.
      # Neither "priv" nor "static" are in the ignored list, so files under
      # priv/static will be returned. This documents the current (buggy) behavior.
      File.mkdir_p!(Path.join([tmp, "priv", "static"]))
      File.write!(Path.join([tmp, "priv", "static", "app.js"]), "")

      result = FileTree.list(tmp)

      # Current behavior: priv/static files ARE returned (not filtered)
      assert "priv/static/app.js" in result
    end

    test "arbitrary hidden directories (starting with dot) are excluded", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".my_hidden_dir"))
      File.write!(Path.join([tmp, ".my_hidden_dir", "secret.txt"]), "")
      File.write!(Path.join(tmp, ".dotfile"), "")
      File.write!(Path.join(tmp, "normal.ex"), "")

      result = FileTree.list(tmp)

      assert result == ["normal.ex"]
    end

    test "non-hidden directories that share prefix with ignored ones are included", %{tmp: tmp} do
      # "deps_local" should NOT be ignored just because "deps" is ignored
      File.mkdir_p!(Path.join(tmp, "deps_local"))
      File.write!(Path.join([tmp, "deps_local", "lib.ex"]), "")

      result = FileTree.list(tmp)

      assert "deps_local/lib.ex" in result
    end
  end

  # ── AC: search returns files containing query in the path ──────────

  describe "search/4 returns files containing query" do
    test "search for 'home_live' returns matching paths", %{tmp: tmp} do
      files = [
        "lib/forge_web/live/home_live.ex",
        "lib/forge_web/live/dashboard_live.ex",
        "test/forge_web/live/home_live_test.exs",
        "lib/forge/session.ex"
      ]

      result = FileTree.search(tmp, "home_live", files)

      assert "lib/forge_web/live/home_live.ex" in result
      assert "test/forge_web/live/home_live_test.exs" in result
      refute "lib/forge_web/live/dashboard_live.ex" in result
      refute "lib/forge/session.ex" in result
    end

    test "search matches anywhere in the path, not just basename", %{tmp: tmp} do
      files = ["src/utils/helpers.ex", "lib/utils_old/thing.ex"]

      result = FileTree.search(tmp, "utils", files)

      assert length(result) == 2
    end
  end

  # ── AC: Basename matches rank before full path matches ─────────────

  describe "search/4 ranking: basename before full path" do
    test "basename match comes before directory-only match", %{tmp: tmp} do
      files = [
        "home_live/config.ex",
        "lib/other/home_live.ex"
      ]

      result = FileTree.search(tmp, "home_live", files)

      # "lib/other/home_live.ex" has "home_live" in its basename
      # "home_live/config.ex" has "home_live" only in a directory component
      basename_idx = Enum.find_index(result, &(&1 == "lib/other/home_live.ex"))
      path_idx = Enum.find_index(result, &(&1 == "home_live/config.ex"))

      assert basename_idx < path_idx,
             "basename match (#{basename_idx}) should rank before path match (#{path_idx})"
    end

    test "multiple basename matches all rank before path-only matches", %{tmp: tmp} do
      files = [
        "query_dir/unrelated.ex",
        "lib/query.ex",
        "src/query_helper.ex",
        "query_dir/other.txt"
      ]

      result = FileTree.search(tmp, "query", files)

      # basename matches: lib/query.ex, src/query_helper.ex
      # path-only matches: query_dir/unrelated.ex, query_dir/other.txt
      basename_indices =
        ["lib/query.ex", "src/query_helper.ex"]
        |> Enum.map(&Enum.find_index(result, fn x -> x == &1 end))
        |> Enum.reject(&is_nil/1)

      path_only_indices =
        ["query_dir/unrelated.ex", "query_dir/other.txt"]
        |> Enum.map(&Enum.find_index(result, fn x -> x == &1 end))
        |> Enum.reject(&is_nil/1)

      max_basename = Enum.max(basename_indices)
      min_path = Enum.min(path_only_indices)

      assert max_basename < min_path,
             "All basename matches should rank before any path-only match"
    end
  end

  # ── AC: Large repos are capped at 5000 files ──────────────────────

  describe "max_files cap" do
    test "default cap is 5000 files", %{tmp: tmp} do
      # Create a structure that would exceed 5000 if uncapped
      # Use 51 dirs * 100 files = 5100 potential files
      for i <- 1..51 do
        dir = Path.join(tmp, "dir_#{String.pad_leading("#{i}", 3, "0")}")
        File.mkdir_p!(dir)

        for j <- 1..100 do
          File.write!(Path.join(dir, "file_#{String.pad_leading("#{j}", 3, "0")}.ex"), "")
        end
      end

      result = FileTree.list(tmp)

      assert length(result) <= 5000,
             "Expected at most 5000 files, got #{length(result)}"

      assert length(result) > 0, "Should return some files"
    end

    test "explicit max_files option overrides default", %{tmp: tmp} do
      for i <- 1..20 do
        File.write!(Path.join(tmp, "file_#{String.pad_leading("#{i}", 2, "0")}.ex"), "")
      end

      result = FileTree.list(tmp, max_files: 5)

      assert length(result) == 5
    end
  end

  # ── AC: Invalid paths return empty list ────────────────────────────

  describe "invalid paths return empty list" do
    test "nonexistent directory returns empty list" do
      assert FileTree.list("/tmp/absolutely_does_not_exist_#{System.unique_integer([:positive])}") == []
    end

    test "path to a regular file (not directory) returns empty list", %{tmp: tmp} do
      file_path = Path.join(tmp, "just_a_file.txt")
      File.write!(file_path, "content")

      assert FileTree.list(file_path) == []
    end

    test "empty string path returns empty list" do
      assert FileTree.list("") == []
    end

    test "search with invalid path and no preloaded files returns empty list" do
      result = FileTree.search("/nonexistent_#{System.unique_integer([:positive])}", "query", nil)
      assert result == []
    end
  end

  # ── Additional edge cases ──────────────────────────────────────────

  describe "edge cases" do
    test "empty directory returns empty list", %{tmp: tmp} do
      assert FileTree.list(tmp) == []
    end

    test "directory with only ignored subdirs returns empty list", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".git"))
      File.write!(Path.join([tmp, ".git", "HEAD"]), "")
      File.mkdir_p!(Path.join(tmp, "node_modules"))
      File.write!(Path.join([tmp, "node_modules", "pkg.js"]), "")

      assert FileTree.list(tmp) == []
    end

    test "files with special characters in names are included", %{tmp: tmp} do
      File.write!(Path.join(tmp, "file with spaces.ex"), "")
      File.write!(Path.join(tmp, "file-with-dashes.ex"), "")
      File.write!(Path.join(tmp, "file_with_underscores.ex"), "")

      result = FileTree.list(tmp)

      assert length(result) == 3
      assert "file with spaces.ex" in result
      assert "file-with-dashes.ex" in result
      assert "file_with_underscores.ex" in result
    end

    test "symlinks to files are included", %{tmp: tmp} do
      real_file = Path.join(tmp, "real.ex")
      File.write!(real_file, "")
      link_path = Path.join(tmp, "link.ex")
      File.ln_s!(real_file, link_path)

      result = FileTree.list(tmp)

      assert "link.ex" in result
      assert "real.ex" in result
    end

    test "search with preloaded files list avoids re-scanning directory", %{tmp: tmp} do
      # Pass files directly — should not need to scan the directory
      files = ["a.ex", "b.ex", "c.ex"]

      result = FileTree.search(tmp, "b", files)

      assert result == ["b.ex"]
    end

    test "search default limit is 15", %{tmp: tmp} do
      files = for i <- 1..30, do: "match_#{i}.ex"

      result = FileTree.search(tmp, "match", files)

      assert length(result) == 15
    end
  end
end
