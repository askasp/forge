defmodule Forge.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias Forge.PromptBuilder

  # Minimal project struct for testing
  defp test_project(opts \\ []) do
    %Forge.Project{
      path: Keyword.get(opts, :path, "/tmp/test-project"),
      name: "test",
      skills: Keyword.get(opts, :skills, []),
      conventions: Keyword.get(opts, :conventions, ""),
      context: nil
    }
  end

  describe "build/4 with images" do
    test "includes <images> section when images are provided" do
      project = test_project()
      result = PromptBuilder.build(project, :dev, "do something", images: ["screenshot.png", "diagram.jpg"])

      assert result =~ "<images>"
      assert result =~ "</images>"
      assert result =~ ".forge/images/screenshot.png"
      assert result =~ ".forge/images/diagram.jpg"
      assert result =~ "Reference images have been provided"
    end

    test "formats image paths correctly with .forge/images/ prefix" do
      project = test_project()
      result = PromptBuilder.build(project, :dev, "task", images: ["ui-mock.png"])

      assert result =~ "- .forge/images/ui-mock.png"
    end

    test "includes multiple image paths on separate lines" do
      project = test_project()
      filenames = ["a.png", "b.jpg", "c.gif"]
      result = PromptBuilder.build(project, :qa, "verify", images: filenames)

      assert result =~ "- .forge/images/a.png\n- .forge/images/b.jpg\n- .forge/images/c.gif"
    end
  end

  describe "build/3 without images" do
    test "does NOT include <images> section when no images option given" do
      project = test_project()
      result = PromptBuilder.build(project, :dev, "do something")

      refute result =~ "<images>"
      refute result =~ "</images>"
    end

    test "does NOT include <images> section with empty images list" do
      project = test_project()
      result = PromptBuilder.build(project, :dev, "do something", images: [])

      refute result =~ "<images>"
      refute result =~ "</images>"
    end

    test "does NOT include <images> section with nil images" do
      project = test_project()
      result = PromptBuilder.build(project, :dev, "do something", images: nil)

      refute result =~ "<images>"
      refute result =~ "</images>"
    end
  end

  describe "build/3 general structure" do
    test "includes role section" do
      project = test_project()
      result = PromptBuilder.build(project, :dev, "implement feature")

      assert result =~ "<role>"
      assert result =~ "@dev agent"
      assert result =~ "</role>"
    end

    test "includes task section" do
      project = test_project()
      result = PromptBuilder.build(project, :dev, "implement feature X")

      assert result =~ "<task>"
      assert result =~ "implement feature X"
      assert result =~ "</task>"
    end

    test "includes conventions section" do
      project = test_project(conventions: "Use 2-space indentation")
      result = PromptBuilder.build(project, :dev, "task")

      assert result =~ "<project-conventions>"
      assert result =~ "Use 2-space indentation"
    end
  end

  describe "builtin_prompt/1" do
    test "returns prompt for known roles" do
      assert PromptBuilder.builtin_prompt(:dev) =~ "@dev agent"
      assert PromptBuilder.builtin_prompt(:qa) =~ "@qa agent"
      assert PromptBuilder.builtin_prompt(:reviewer) =~ "@reviewer agent"
      assert PromptBuilder.builtin_prompt(:planner) =~ "@planner agent"
    end

    test "returns nil for unknown role" do
      assert PromptBuilder.builtin_prompt(:unknown) == nil
    end
  end

  describe "builtin_roles/0" do
    test "returns all built-in roles" do
      roles = PromptBuilder.builtin_roles()
      assert :planner in roles
      assert :dev in roles
      assert :qa in roles
      assert :reviewer in roles
    end
  end
end
