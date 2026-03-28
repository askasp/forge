defmodule ForgeWeb.KeyboardShortcutsHookTest do
  @moduledoc """
  Tests verifying the keyboard_shortcuts.js and home_shortcuts.js hook
  source code has the correct structure — event guards, key bindings, and
  event names. These are static analysis tests since we cannot execute
  browser JS in ExUnit, but they ensure the hook files stay correct.
  """
  use ExUnit.Case, async: true

  @keyboard_shortcuts_path "assets/js/hooks/keyboard_shortcuts.js"
  @home_shortcuts_path "assets/js/hooks/home_shortcuts.js"
  @app_js_path "assets/js/app.js"

  setup_all do
    kb_source = File.read!(@keyboard_shortcuts_path)
    home_source = File.read!(@home_shortcuts_path)
    app_source = File.read!(@app_js_path)
    %{kb_source: kb_source, home_source: home_source, app_source: app_source}
  end

  describe "keyboard_shortcuts.js (dashboard)" do
    test "guards against INPUT/TEXTAREA/SELECT focus", %{kb_source: src} do
      # The hook must skip shortcuts when typing in form elements
      assert src =~ "INPUT"
      assert src =~ "TEXTAREA"
      assert src =~ "SELECT"
      assert src =~ "e.target.tagName"
      # Verify it returns early when focused on these elements
      assert src =~ ~r/if.*tag\s*===\s*"INPUT".*return/s
    end

    test "binds Cmd+B to toggle_sidebar", %{kb_source: src} do
      assert src =~ ~r/metaKey.*ctrlKey.*"b"/s
      assert src =~ "toggle_sidebar"
    end

    test "binds Alt+N to new_session", %{kb_source: src} do
      assert src =~ ~r/altKey.*"n"/s
      assert src =~ "new_session"
    end

    test "binds Cmd+K to toggle_ask", %{kb_source: src} do
      assert src =~ ~r/metaKey.*ctrlKey.*"k"/s
      assert src =~ "toggle_ask"
    end

    test "binds Cmd+Enter to continue", %{kb_source: src} do
      assert src =~ ~r/metaKey.*ctrlKey.*"Enter"/s
      assert src =~ "continue"
    end

    test "binds Escape to pause", %{kb_source: src} do
      assert src =~ "Escape"
      assert src =~ "pause"
    end

    test "binds Cmd+. to skip", %{kb_source: src} do
      assert src =~ ~r/metaKey.*ctrlKey.*"\."/s
      assert src =~ "skip"
    end

    test "binds ? to toggle_shortcuts", %{kb_source: src} do
      assert src =~ ~s(e.key === "?")
      assert src =~ "toggle_shortcuts"
    end

    test "uses pushEvent to communicate with LiveView", %{kb_source: src} do
      assert src =~ "pushEvent"
    end

    test "registers keydown listener on mount and removes on destroy", %{kb_source: src} do
      assert src =~ ~s(addEventListener("keydown")
      assert src =~ ~s(removeEventListener("keydown")
      assert src =~ "mounted()"
      assert src =~ "destroyed()"
    end
  end

  describe "home_shortcuts.js" do
    test "binds Cmd+Enter to submit start_session form", %{home_source: src} do
      assert src =~ ~r/metaKey.*ctrlKey.*"Enter"/s
      assert src =~ "start_session"
      assert src =~ "requestSubmit"
    end

    test "finds form by phx-submit=start_session selector", %{home_source: src} do
      assert src =~ ~s(phx-submit="start_session")
    end

    test "registers keydown listener on mount and removes on destroy", %{home_source: src} do
      assert src =~ ~s(addEventListener("keydown")
      assert src =~ ~s(removeEventListener("keydown")
    end

    test "does NOT guard against input/textarea focus (form submit should work anywhere)", %{
      home_source: src
    } do
      # HomeShortcuts intentionally does NOT skip when focused on textarea
      # because the user types a goal in the textarea and presses Cmd+Enter to submit
      refute src =~ "tagName"
      refute src =~ ~s("INPUT")
    end
  end

  describe "app.js hook registration" do
    test "registers KeyboardShortcuts hook", %{app_source: src} do
      assert src =~ "KeyboardShortcuts"
    end

    test "registers HomeShortcuts hook", %{app_source: src} do
      assert src =~ "HomeShortcuts"
    end

    test "imports both hook modules", %{app_source: src} do
      assert src =~ ~r/import.*keyboard_shortcuts/
      assert src =~ ~r/import.*home_shortcuts/
    end
  end
end
