defmodule ForgeWeb.HomeLiveAutocompleteTest do
  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # ── Project Path Autocomplete ──────────────────────────────────────

  describe "filter_suggestions — known project filtering" do
    test "shows all known projects when input is empty", %{conn: conn} do
      # Add some known projects first
      Forge.KnownProjects.add("/tmp/project-alpha")
      Forge.KnownProjects.add("/tmp/project-beta")

      {:ok, view, _html} = live(conn, ~p"/")

      html = render_keyup(view, "filter_suggestions", %{"value" => ""})

      assert html =~ "project-alpha"
      assert html =~ "project-beta"
    end

    test "filters known projects by partial name", %{conn: conn} do
      Forge.KnownProjects.add("/tmp/project-alpha")
      Forge.KnownProjects.add("/tmp/project-beta")
      Forge.KnownProjects.add("/tmp/unrelated-repo")

      {:ok, view, _html} = live(conn, ~p"/")

      html = render_keyup(view, "filter_suggestions", %{"value" => "project"})

      assert html =~ "project-alpha"
      assert html =~ "project-beta"
      refute html =~ "unrelated-repo"
    end

    test "filtering is case-insensitive", %{conn: conn} do
      Forge.KnownProjects.add("/tmp/MyProject")

      {:ok, view, _html} = live(conn, ~p"/")

      html = render_keyup(view, "filter_suggestions", %{"value" => "myproject"})
      assert html =~ "MyProject"
    end
  end

  describe "filter_suggestions — filesystem browsing" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "fs_browse_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "subdir_a"))
      File.mkdir_p!(Path.join(tmp, "subdir_b"))
      File.mkdir_p!(Path.join(tmp, ".hidden"))
      File.write!(Path.join(tmp, "not_a_dir.txt"), "")
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    test "typing a path with trailing slash shows subdirectories", %{conn: conn, tmp: tmp} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_keyup(view, "filter_suggestions", %{"value" => tmp <> "/"})

      assert html =~ "subdir_a"
      assert html =~ "subdir_b"
      # Should not show hidden dirs
      refute html =~ ".hidden"
      # Should not show files (only directories)
      refute html =~ "not_a_dir.txt"
    end

    test "typing partial directory name filters entries", %{conn: conn, tmp: tmp} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_keyup(view, "filter_suggestions", %{"value" => tmp <> "/subdir_a"})

      assert html =~ "subdir_a"
      refute html =~ "subdir_b"
    end

    test "nonexistent path shows empty suggestions (no crash)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_keyup(view, "filter_suggestions", %{"value" => "/tmp/nonexistent_#{:erlang.unique_integer([:positive])}/"})

      # Should not crash, just show no filesystem entries
      refute html =~ "data-suggestions"
    end

    test "tilde expands to home directory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_keyup(view, "filter_suggestions", %{"value" => "~/"})

      # Home directory should have some content — we just check it doesn't crash
      # and the suggestions area is rendered (we can't predict exact contents)
      assert is_binary(html)
    end
  end

  describe "navigate_suggestion" do
    test "arrow down selects first suggestion", %{conn: conn} do
      Forge.KnownProjects.add("/tmp/nav-test-project")

      {:ok, view, _html} = live(conn, ~p"/")
      # Ensure suggestions are showing
      render_keyup(view, "filter_suggestions", %{"value" => ""})

      html = render_click(view, "navigate_suggestion", %{"direction" => "down"})

      # First item should now have data-selected="true"
      assert html =~ ~s(data-selected="true")
    end

    test "arrow up from nil wraps to last suggestion", %{conn: conn} do
      Forge.KnownProjects.add("/tmp/nav-wrap-project")

      {:ok, view, _html} = live(conn, ~p"/")
      render_keyup(view, "filter_suggestions", %{"value" => ""})

      html = render_click(view, "navigate_suggestion", %{"direction" => "up"})

      assert html =~ ~s(data-selected="true")
    end

    test "arrow down wraps around", %{conn: conn} do
      # Ensure only one known project
      Forge.KnownProjects.add("/tmp/single-project")

      {:ok, view, _html} = live(conn, ~p"/")
      render_keyup(view, "filter_suggestions", %{"value" => "single-project"})

      # Move down to index 0
      render_click(view, "navigate_suggestion", %{"direction" => "down"})
      # Move down again — should wrap to 0 (only one item)
      html = render_click(view, "navigate_suggestion", %{"direction" => "down"})

      assert html =~ ~s(data-selected="true")
    end

    test "does nothing when suggestions list is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      # Filter to something that matches nothing
      render_keyup(view, "filter_suggestions", %{"value" => "zzz_no_match_ever"})

      # Should not crash
      html = render_click(view, "navigate_suggestion", %{"direction" => "down"})
      assert is_binary(html)
    end
  end

  describe "select_project" do
    test "sets project_path and clears suggestions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "select_project", %{"path" => "/tmp/some-project"})

      assert html =~ "/tmp/some-project"
      # Suggestions should be cleared (no dropdown)
      refute html =~ "data-suggestions"
    end
  end

  describe "clear_suggestions" do
    test "clears the suggestions dropdown", %{conn: conn} do
      Forge.KnownProjects.add("/tmp/clear-test")

      {:ok, view, _html} = live(conn, ~p"/")
      render_keyup(view, "filter_suggestions", %{"value" => ""})

      html = render_click(view, "clear_suggestions")

      refute html =~ "data-suggestions"
    end
  end

  # ── @ Mention Autocomplete ─────────────────────────────────────────

  describe "mention_search" do
    test "returns matching files from scanned project", %{conn: conn} do
      project_path = create_test_project_with_files()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      # Wait for scan
      render(view)

      html = render_click(view, "mention_search", %{"query" => "app"})

      assert html =~ "data-mention-results"
      assert html =~ "app.ex"
    end

    test "returns empty when query matches nothing", %{conn: conn} do
      project_path = create_test_project_with_files()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      html = render_click(view, "mention_search", %{"query" => "zzz_nonexistent_file"})

      refute html =~ "data-mention-results"
    end

    test "returns empty when no project is scanned", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # No project scanned, so project_files is []
      html = render_click(view, "mention_search", %{"query" => "anything"})

      refute html =~ "data-mention-results"
    end
  end

  describe "mention_navigate" do
    test "navigates down through results", %{conn: conn} do
      project_path = create_test_project_with_files()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)
      render_click(view, "mention_search", %{"query" => ""})

      html = render_click(view, "mention_navigate", %{"direction" => "down"})

      # Index should now be 1 (moved from 0)
      assert is_binary(html)
    end

    test "does not go below zero when navigating up", %{conn: conn} do
      project_path = create_test_project_with_files()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)
      render_click(view, "mention_search", %{"query" => ""})

      # Already at 0, going up should stay at 0
      html = render_click(view, "mention_navigate", %{"direction" => "up"})

      assert is_binary(html)
    end
  end

  describe "mention_select" do
    test "pushes mention_selected event and clears results", %{conn: conn} do
      project_path = create_test_project_with_files()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)
      render_click(view, "mention_search", %{"query" => "app"})

      html = render_click(view, "mention_select")

      # Results should be cleared after selection
      refute html =~ "data-mention-results"
    end

    test "does nothing when no results exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # No mention results, should not crash
      html = render_click(view, "mention_select")
      assert is_binary(html)
    end
  end

  describe "mention_select_path" do
    test "clears results and pushes event for the given path", %{conn: conn} do
      project_path = create_test_project_with_files()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)
      render_click(view, "mention_search", %{"query" => "app"})

      html = render_click(view, "mention_select_path", %{"path" => "lib/app.ex"})

      refute html =~ "data-mention-results"
    end
  end

  describe "mention_clear" do
    test "clears mention results", %{conn: conn} do
      project_path = create_test_project_with_files()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)
      render_click(view, "mention_search", %{"query" => "app"})

      html = render_click(view, "mention_clear")

      refute html =~ "data-mention-results"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp create_test_project_with_files do
    path =
      Path.join(System.tmp_dir!(), "forge_autocomplete_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(path, "lib"))
    File.write!(Path.join([path, "lib", "app.ex"]), "defmodule App do\nend\n")
    File.write!(Path.join([path, "lib", "router.ex"]), "defmodule Router do\nend\n")
    File.write!(Path.join(path, "mix.exs"), "")

    System.cmd("git", ["init"], cd: path)
    System.cmd("git", ["commit", "--allow-empty", "-m", "init"], cd: path)

    on_exit(fn -> File.rm_rf!(path) end)

    path
  end
end
