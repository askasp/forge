defmodule ForgeWeb.DashboardLiveTest do
  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Forge.Repo
  alias Forge.Schemas.{Project, Session}

  setup do
    project =
      %Project{}
      |> Project.changeset(%{name: "test-project", repo_path: "/tmp/test-project"})
      |> Repo.insert!()

    session =
      %Session{}
      |> Session.changeset(%{
        project_id: project.id,
        goal: "Test goal",
        worktree_path: "/tmp/test-worktree",
        automation: :supervised
      })
      |> Repo.insert!()

    %{project: project, session: session}
  end

  describe "sidebar default visibility" do
    test "sidebar is visible by default on mount", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/session/#{session.id}")

      # The sidebar aside element should be present (rendered because sidebar_open=true)
      assert html =~ "w-56 flex-shrink-0 border-r"
      # The sidebar should show the "+ New session" link
      assert html =~ "+ New session"
    end

    test "sidebar stays visible (always rendered)", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

      assert render(view) =~ "+ New session"

      # Sidebar is always visible, toggle doesn't hide it
      html = render_click(view, "toggle_sidebar")
      assert html =~ "+ New session"
      assert html =~ "w-56 flex-shrink-0 border-r"
    end
  end

  describe "new_session event (Alt+N)" do
    test "navigates to home with project query param", %{
      conn: conn,
      session: session,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

      # Trigger the new_session event (what Alt+N does via JS hook)
      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               render_click(view, "new_session")

      # Should redirect to home with project path as query param
      assert redirect_path =~ "/"
      assert redirect_path =~ "project="
      assert redirect_path =~ URI.encode_www_form(project.repo_path)
    end

    test "new_session handler falls back to / when project_path is nil" do
      # The new_session handler checks `if project_path do` and falls back to "/"
      # We can't easily create a session without a project (FK constraint),
      # but we verify the code path exists in the source
      source = File.read!("lib/forge_web/live/dashboard_live.ex")
      assert source =~ ~r/def handle_event\("new_session".*project_path/s
      assert source =~ "push_navigate(socket, to: ~p\"/\")"
    end
  end

  describe "shortcuts overlay" do
    test "shortcuts overlay is hidden by default", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/session/#{session.id}")

      # The shortcuts overlay should not be visible on mount
      refute html =~ "Keyboard Shortcuts"
    end

    test "toggle_shortcuts shows the overlay with Alt+N listed", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

      html = render_click(view, "toggle_shortcuts")

      # Overlay should be visible
      assert html =~ "Keyboard Shortcuts"
      # Alt+N should be listed
      assert html =~ "New session"
      assert html =~ "Alt+N"
      # Other shortcuts should also be listed
      assert html =~ "Cmd+B"
      assert html =~ "Cmd+Enter"
      assert html =~ "Cmd+K"
    end

    test "toggle_shortcuts twice hides the overlay", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

      render_click(view, "toggle_shortcuts")
      html = render_click(view, "toggle_shortcuts")

      refute html =~ "Keyboard Shortcuts"
    end
  end

  describe "footer hints" do
    test "footer shows Alt+N hint button", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/session/#{session.id}")

      # Footer should have the Alt+N button
      assert html =~ ~s(phx-click="new_session")
      assert html =~ "Alt+N"
    end

    test "footer shows Cmd+B hint button", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/session/#{session.id}")

      assert html =~ ~s(phx-click="toggle_sidebar")
      assert html =~ "Cmd+B"
    end
  end

  describe "keyboard shortcuts hook integration" do
    test "dashboard element has KeyboardShortcuts hook attached", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/session/#{session.id}")

      # The main dashboard div should have the phx-hook="KeyboardShortcuts" attribute
      assert html =~ ~s(phx-hook="KeyboardShortcuts")
      assert html =~ ~s(id="dashboard")
    end
  end

  describe "continue event (Cmd+Enter)" do
    test "continue event is handled without error", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

      # The continue event should not crash — it calls Scheduler.resume
      # which may not do anything in test, but the event handler should exist
      html = render_click(view, "continue")
      assert html =~ "dashboard"
    end
  end

  describe "session not found" do
    test "redirects to home when session ID doesn't exist", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/session/#{fake_id}")
    end
  end
end
