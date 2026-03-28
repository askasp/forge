defmodule ForgeWeb.HomeLiveTest do
  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "mount without project param" do
    test "renders the home page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Forge"
      assert html =~ "Project Path"
    end

    test "project_path starts empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The input should have empty value
      assert html =~ ~s(name="project_path")
    end

    test "scan section is not shown initially", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # No goal textarea since scan hasn't happened
      refute html =~ "Describe what you want to build"
    end
  end

  describe "mount with project query param" do
    test "pre-fills the project path from URL", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/?project=/tmp/test-project")

      # The project path should be pre-filled
      assert html =~ "/tmp/test-project"
    end

    test "triggers auto-scan for valid project path", %{conn: conn} do
      # Create a temporary project directory with a git repo so scan succeeds
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")

      # Wait for the async scan message to be processed
      # The :do_scan info handler will fire after mount
      html = render(view)

      # After scan completes, the goal textarea should be visible
      assert html =~ "Describe what you want to build"
      assert html =~ "Start Session"

      cleanup_test_project(project_path)
    end
  end

  describe "home page has HomeShortcuts hook" do
    test "home div has HomeShortcuts hook attached", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(phx-hook="HomeShortcuts")
      assert html =~ ~s(id="home")
    end
  end

  describe "start_session form" do
    test "form exists with phx-submit=start_session after scan", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      html = render(view)

      assert html =~ ~s(phx-submit="start_session")

      cleanup_test_project(project_path)
    end

    test "start_session requires a goal", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      # Wait for scan
      render(view)

      html = render_submit(view, "start_session", %{"goal" => ""})
      assert html =~ "Goal is required"

      cleanup_test_project(project_path)
    end

    test "start_session requires config to be saved first", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      # Wait for scan
      render(view)

      html = render_submit(view, "start_session", %{"goal" => "Build a feature"})
      assert html =~ "Save config before starting"

      cleanup_test_project(project_path)
    end
  end

  describe "scan_project event" do
    test "scanning empty path clears state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_submit(view, "scan_project", %{"project_path" => ""})

      refute html =~ "Describe what you want to build"
    end

    test "scanning invalid path shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_submit(view, "scan_project", %{"project_path" => "/nonexistent/path/abc123"})

      # Should show an error message
      assert html =~ "border-l-4"
    end
  end

  describe "automation level" do
    test "defaults to supervised", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      html = render(view)

      # The supervised radio should be checked (shown as selected style)
      assert html =~ "Supervised"

      cleanup_test_project(project_path)
    end

    test "set_automation changes the level", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      html = render_click(view, "set_automation", %{"level" => "autopilot"})
      # Autopilot should now have the selected style
      assert html =~ "Autopilot"

      cleanup_test_project(project_path)
    end
  end

  # -- Test helpers --

  defp create_test_project do
    path = Path.join(System.tmp_dir!(), "forge_test_project_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(path)

    # Initialize a git repo so ProjectScanner.scan succeeds
    System.cmd("git", ["init"], cd: path)
    System.cmd("git", ["commit", "--allow-empty", "-m", "init"], cd: path)

    path
  end

  defp cleanup_test_project(path) do
    File.rm_rf!(path)
  end
end
