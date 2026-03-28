defmodule Forge.FileTreeTest do
  use ExUnit.Case, async: true

  alias Forge.FileTree

  setup do
    tmp = Path.join(System.tmp_dir!(), "file_tree_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  describe "list/2" do
    test "returns files in a flat directory", %{tmp: tmp} do
      File.write!(Path.join(tmp, "a.ex"), "")
      File.write!(Path.join(tmp, "b.ex"), "")

      result = FileTree.list(tmp)

      assert result == ["a.ex", "b.ex"]
    end

    test "returns nested files with relative paths", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "lib"))
      File.write!(Path.join([tmp, "lib", "app.ex"]), "")
      File.write!(Path.join(tmp, "mix.exs"), "")

      result = FileTree.list(tmp)

      assert result == ["lib/app.ex", "mix.exs"]
    end

    test "skips ignored directories like .git and node_modules", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".git"))
      File.write!(Path.join([tmp, ".git", "HEAD"]), "ref: refs/heads/main")
      File.mkdir_p!(Path.join(tmp, "node_modules"))
      File.write!(Path.join([tmp, "node_modules", "pkg.js"]), "")
      File.mkdir_p!(Path.join(tmp, "_build"))
      File.write!(Path.join([tmp, "_build", "out"]), "")
      File.write!(Path.join(tmp, "main.ex"), "")

      result = FileTree.list(tmp)

      assert result == ["main.ex"]
    end

    test "skips dotfiles and dot directories", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".hidden"))
      File.write!(Path.join([tmp, ".hidden", "secret"]), "")
      File.write!(Path.join(tmp, ".env"), "")
      File.write!(Path.join(tmp, "visible.ex"), "")

      result = FileTree.list(tmp)

      # .env is a file starting with dot — ignored by the ignored? check
      # .hidden is a dir starting with dot — also ignored
      assert result == ["visible.ex"]
    end

    test "respects max_depth option", %{tmp: tmp} do
      File.mkdir_p!(Path.join([tmp, "a", "b", "c"]))
      File.write!(Path.join([tmp, "a", "top.ex"]), "")
      File.write!(Path.join([tmp, "a", "b", "mid.ex"]), "")
      File.write!(Path.join([tmp, "a", "b", "c", "deep.ex"]), "")

      # max_depth 1: only root + 1 level deep
      shallow = FileTree.list(tmp, max_depth: 1)
      assert "a/top.ex" in shallow
      refute "a/b/mid.ex" in shallow

      # max_depth 2: root + 2 levels
      medium = FileTree.list(tmp, max_depth: 2)
      assert "a/top.ex" in medium
      assert "a/b/mid.ex" in medium
      refute "a/b/c/deep.ex" in medium
    end

    test "respects max_files option", %{tmp: tmp} do
      for i <- 1..10, do: File.write!(Path.join(tmp, "file_#{String.pad_leading("#{i}", 2, "0")}.ex"), "")

      result = FileTree.list(tmp, max_files: 3)

      assert length(result) == 3
    end

    test "returns empty list for nonexistent directory" do
      result = FileTree.list("/tmp/nonexistent_dir_#{:erlang.unique_integer([:positive])}")
      assert result == []
    end

    test "returns sorted results", %{tmp: tmp} do
      File.write!(Path.join(tmp, "zebra.ex"), "")
      File.write!(Path.join(tmp, "alpha.ex"), "")
      File.write!(Path.join(tmp, "middle.ex"), "")

      result = FileTree.list(tmp)

      assert result == ["alpha.ex", "middle.ex", "zebra.ex"]
    end
  end

  describe "search/4" do
    test "filters files matching the query (case-insensitive)", %{tmp: tmp} do
      files = ["lib/app.ex", "lib/router.ex", "test/app_test.exs"]

      result = FileTree.search(tmp, "app", files)

      assert "lib/app.ex" in result
      assert "test/app_test.exs" in result
      refute "lib/router.ex" in result
    end

    test "prioritizes basename matches over path-only matches", %{tmp: tmp} do
      files = ["lib/utils/helper.ex", "helper/config.ex", "src/helper.ex"]

      result = FileTree.search(tmp, "helper", files)

      # basename matches: lib/utils/helper.ex, src/helper.ex
      # path match: helper/config.ex (basename is "config.ex", but path contains "helper")
      # Basename matches should come first
      basename_positions =
        Enum.map(["lib/utils/helper.ex", "src/helper.ex"], fn f ->
          Enum.find_index(result, &(&1 == f))
        end)

      path_position = Enum.find_index(result, &(&1 == "helper/config.ex"))

      assert Enum.all?(basename_positions, &(&1 < path_position))
    end

    test "is case-insensitive", %{tmp: tmp} do
      files = ["lib/MyModule.ex", "lib/mymodule_test.exs"]

      result = FileTree.search(tmp, "mymodule", files)
      assert length(result) == 2

      result_upper = FileTree.search(tmp, "MyModule", files)
      assert length(result_upper) == 2
    end

    test "respects limit parameter", %{tmp: tmp} do
      files = for i <- 1..20, do: "file_#{i}.ex"

      result = FileTree.search(tmp, "file", files, 5)

      assert length(result) == 5
    end

    test "returns empty list when nothing matches", %{tmp: tmp} do
      files = ["lib/app.ex", "lib/router.ex"]

      result = FileTree.search(tmp, "zzzznonexistent", files)

      assert result == []
    end

    test "uses list/1 when files argument is nil", %{tmp: tmp} do
      File.write!(Path.join(tmp, "target.ex"), "")
      File.write!(Path.join(tmp, "other.ex"), "")

      result = FileTree.search(tmp, "target", nil)

      assert result == ["target.ex"]
    end

    test "empty query matches everything", %{tmp: tmp} do
      files = ["a.ex", "b.ex", "c.ex"]

      result = FileTree.search(tmp, "", files)

      assert length(result) == 3
    end
  end
end
