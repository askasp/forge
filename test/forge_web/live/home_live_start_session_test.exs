defmodule ForgeWeb.HomeLiveStartSessionTest do
  @moduledoc """
  Tests for the async session creation flow in HomeLive.
  Covers: start_async/handle_async pattern, loading state, error handling,
  and consolidated session creation path.
  """
  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # ── Creating assign initialization ────────────────────────────────

  describe "mount initializes :creating as false" do
    test "Start Session button shows default text (not loading)", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      html = render(view)

      assert html =~ "Start Session →"
      refute html =~ "Creating..."

      cleanup_test_project(project_path)
    end

    test "submit button is not disabled initially", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      html = render(view)

      # The submit button should not have disabled attribute
      # Find the submit button - it contains "Start Session"
      refute html =~ "opacity-50 cursor-wait"

      cleanup_test_project(project_path)
    end

    test "textarea is not disabled initially", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      html = render(view)

      # The goal textarea should not be disabled
      # Parse for the textarea with name="goal" - it should not have disabled=""
      [textarea_match] = Regex.scan(~r/<textarea[^>]*name="goal"[^>]*>/, html)
      refute hd(textarea_match) =~ "disabled"

      cleanup_test_project(project_path)
    end
  end

  # ── Loading state during creation ─────────────────────────────────

  describe "loading state when start_session is submitted" do
    test "button shows 'Creating...' after form submit", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      # Submit the form — async task starts, view enters :creating state
      html = render_submit(view, "start_session", %{"goal" => "Build a feature"})

      assert html =~ "Creating..."
      refute html =~ "Start Session →"

      cleanup_test_project(project_path)
    end

    test "submit button has disabled attribute during creation", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      html = render_submit(view, "start_session", %{"goal" => "Build a feature"})

      assert html =~ "opacity-50 cursor-wait"

      cleanup_test_project(project_path)
    end

    test "goal textarea is disabled during creation", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      html = render_submit(view, "start_session", %{"goal" => "Build a feature"})

      [textarea_match] = Regex.scan(~r/<textarea[^>]*name="goal"[^>]*>/, html)
      assert hd(textarea_match) =~ "disabled"

      cleanup_test_project(project_path)
    end

    test "automation radio inputs are disabled during creation", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      html = render_submit(view, "start_session", %{"goal" => "Build a feature"})

      # All three automation radios should be disabled
      radio_matches = Regex.scan(~r/<input[^>]*name="automation"[^>]*>/, html)
      assert length(radio_matches) == 3

      for [radio] <- radio_matches do
        assert radio =~ "disabled"
      end

      cleanup_test_project(project_path)
    end
  end

  # ── Validation still works (no async needed) ──────────────────────

  describe "start_session validation" do
    test "empty goal shows error without entering creating state", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      html = render_submit(view, "start_session", %{"goal" => ""})

      assert html =~ "Describe what you want done"
      # Should not enter creating state
      refute html =~ "Creating..."
      assert html =~ "Start Session →"

      cleanup_test_project(project_path)
    end

    test "no project scanned shows error without entering creating state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_submit(view, "start_session", %{"goal" => "Do something"})

      assert html =~ "Scan a project first"
      refute html =~ "Creating..."

      cleanup_test_project("/nonexistent")
    end
  end

  # ── handle_async error case ───────────────────────────────────────

  describe "handle_async error and exit cases" do
    test "session creation error shows 'Failed:' message and resets creating", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      # Submit triggers start_async; Session.create_session will fail on test repo
      render_submit(view, "start_session", %{"goal" => "Build a feature"})

      # Wait for the async task to complete
      html = render_async(view)

      # The error message should be displayed
      assert html =~ "Failed:"
      # Creating state should be reset
      refute html =~ "Creating..."
      assert html =~ "Start Session →"

      cleanup_test_project(project_path)
    end

    test "after error, form inputs are re-enabled", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      render_submit(view, "start_session", %{"goal" => "Build a feature"})
      html = render_async(view)

      # Textarea should no longer be disabled
      [textarea_match] = Regex.scan(~r/<textarea[^>]*name="goal"[^>]*>/, html)
      refute hd(textarea_match) =~ "disabled"

      # Submit button should not have loading style
      refute html =~ "opacity-50 cursor-wait"

      cleanup_test_project(project_path)
    end
  end

  # ── Consolidated session creation path ────────────────────────────

  describe "consolidated session creation (no duplicated logic)" do
    test "auto-saves config for unsaved project and uses start_async", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      # This project has no saved config, so config_saved is false
      # start_session should auto-save config AND use start_async (not synchronous)
      html = render_submit(view, "start_session", %{"goal" => "Build a feature"})

      # Should enter creating state (start_async was used)
      assert html =~ "Creating..."

      # Wait for async to complete — expect error since test repo can't create worktrees
      html = render_async(view)
      assert html =~ "Failed:"

      cleanup_test_project(project_path)
    end

    test "saved config project also uses start_async", %{conn: conn} do
      project_path = create_test_project()

      {:ok, view, _html} = live(conn, "/?project=#{URI.encode(project_path)}")
      render(view)

      # First save the config
      render_submit(view, "save_config", %{
        "skills" => [],
        "test_command" => "",
        "dev_start" => "",
        "branch_prefix" => "wt-",
        "base_branch" => "main"
      })

      # Now start session with saved config
      html = render_submit(view, "start_session", %{"goal" => "Another feature"})

      # Should also enter creating state (same path as unsaved)
      assert html =~ "Creating..."

      # Wait for async to complete
      html = render_async(view)
      assert html =~ "Failed:"

      cleanup_test_project(project_path)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp create_test_project do
    path =
      Path.join(System.tmp_dir!(), "forge_async_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(path)
    System.cmd("git", ["init"], cd: path)
    System.cmd("git", ["commit", "--allow-empty", "-m", "init"], cd: path)

    path
  end

  defp cleanup_test_project(path) do
    File.rm_rf!(path)
  end
end
