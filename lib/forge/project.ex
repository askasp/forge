defmodule Forge.Project do
  @moduledoc """
  Loads project configuration from .forge/config.toml and auto-discovers
  .claude/ agents, skills, and CLAUDE.md conventions.
  """

  defstruct [
    :path,
    :name,
    :test_command,
    :dev_start,
    :dev_stop,
    :screenshot_url,
    :branch_prefix,
    :base_branch,
    :pr_fetch_comments,
    :codex_wait,
    :context,
    role_overrides: %{},
    skills: [],
    conventions: "",
    reviewer_enabled: true
  ]

  @doc "Load project config from a directory path."
  def load(project_path) do
    config = read_config(project_path)

    %__MODULE__{
      path: project_path,
      name: get_in(config, ["project", "name"]) || project_name_from_path(project_path),
      role_overrides: load_role_overrides(project_path),
      skills: load_skills(project_path, get_in(config, ["skills", "include"]) || []),
      conventions: read_claude_mds(project_path),
      context: Forge.ProjectContext.load(project_path),
      test_command: get_in(config, ["commands", "test"]) || "npm test",
      dev_start: get_in(config, ["commands", "dev_start"]),
      dev_stop: get_in(config, ["commands", "dev_stop"]),
      screenshot_url: get_in(config, ["commands", "screenshot_url"]),
      branch_prefix: get_in(config, ["git", "branch_prefix"]) || "wt-",
      base_branch: get_in(config, ["git", "base_branch"]) || "main",
      pr_fetch_comments: get_in(config, ["pr", "fetch_comments"]),
      codex_wait: get_in(config, ["pr", "codex_wait_minutes"]) || 10,
      reviewer_enabled: get_in(config, ["reviewer", "enabled"]) != false
    }
  end

  defp project_name_from_path(path) do
    # Strip worktree suffix like .worktrees/wt-some-session to get the real project name
    path
    |> String.replace(~r/\.worktrees\/.*$/, "")
    |> String.trim_trailing("/")
    |> Path.basename()
  end

  defp read_config(project_path) do
    config_path = Path.join(project_path, ".forge/config.toml")

    if File.exists?(config_path) do
      case Toml.decode_file(config_path) do
        {:ok, config} -> config
        {:error, _} -> %{}
      end
    else
      %{}
    end
  end

  defp load_skills(project_path, skill_names) do
    Enum.flat_map(skill_names, fn name ->
      path = Path.join(project_path, ".claude/skills/#{name}/SKILL.md")

      if File.exists?(path) do
        [{name, File.read!(path)}]
      else
        []
      end
    end)
  end

  defp load_role_overrides(project_path) do
    Path.join(project_path, ".forge/roles/*.md")
    |> Path.wildcard()
    |> Map.new(fn file ->
      {Path.basename(file, ".md"), File.read!(file)}
    end)
  end

  defp read_claude_mds(project_path) do
    paths =
      [Path.join(project_path, "CLAUDE.md")]
      |> Kernel.++(Path.wildcard(Path.join(project_path, "*/CLAUDE.md")))
      |> Enum.filter(&File.exists?/1)

    Enum.map_join(paths, "\n\n---\n\n", fn path ->
      relative = Path.relative_to(path, project_path)
      "# #{relative}\n\n#{File.read!(path)}"
    end)
  end
end
