defmodule Forge.ProjectContext do
  @moduledoc """
  Persistent project memory stored in .forge/context/.
  Accumulates learnings across sessions, git-trackable.
  """

  defstruct [
    :project_path,
    architecture: nil,
    key_files: nil,
    learnings: []
  ]

  @context_dir "context"
  @max_learnings 50

  @doc "Load project context from .forge/context/ directory."
  def load(project_path) do
    # Resolve to main project path (not worktree)
    main_path = resolve_main_path(project_path)
    context_dir = Path.join(main_path, ".forge/#{@context_dir}")

    %__MODULE__{
      project_path: main_path,
      architecture: read_section(context_dir, "architecture.md"),
      key_files: read_section(context_dir, "key_files.md"),
      learnings: read_learnings(context_dir)
    }
  end

  @doc "Update a section of the project context."
  def update_section(%__MODULE__{} = ctx, section, content)
      when section in ["architecture", "key_files"] do
    context_dir = Path.join(ctx.project_path, ".forge/#{@context_dir}")
    File.mkdir_p!(context_dir)
    File.write!(Path.join(context_dir, "#{section}.md"), content)

    case section do
      "architecture" -> %{ctx | architecture: content}
      "key_files" -> %{ctx | key_files: content}
    end
  end

  @doc "Add a learning entry (prepended, capped at #{@max_learnings})."
  def add_learning(%__MODULE__{} = ctx, session_id, text) do
    context_dir = Path.join(ctx.project_path, ".forge/#{@context_dir}")
    File.mkdir_p!(context_dir)

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    entry = "### #{timestamp} (#{session_id})\n#{text}\n"

    learnings_path = Path.join(context_dir, "learnings.md")
    existing = if File.exists?(learnings_path), do: File.read!(learnings_path), else: ""

    # Split into entries, prepend new one, cap at max
    entries = split_learnings(existing)
    entries = [entry | entries] |> Enum.take(@max_learnings)

    content = "# Session Learnings\n\n" <> Enum.join(entries, "\n---\n\n")
    File.write!(learnings_path, content)

    %{ctx | learnings: entries}
  end

  @doc "Format context for injection into agent prompts."
  def format(%__MODULE__{} = ctx, role \\ :dev) do
    sections = []

    sections =
      if ctx.architecture do
        ["## Project Architecture\n#{ctx.architecture}" | sections]
      else
        sections
      end

    sections =
      if ctx.key_files do
        ["## Key Files\n#{ctx.key_files}" | sections]
      else
        sections
      end

    # Only planner gets learnings (to avoid bloating dev/qa prompts)
    sections =
      if role == :planner && ctx.learnings != [] do
        recent = ctx.learnings |> Enum.take(5) |> Enum.join("\n")
        ["## Recent Session Learnings\n#{recent}" | sections]
      else
        sections
      end

    case Enum.reverse(sections) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  @doc "Check if any context exists."
  def empty?(%__MODULE__{} = ctx) do
    is_nil(ctx.architecture) and is_nil(ctx.key_files) and ctx.learnings == []
  end

  # ── Private ──────────────────────────────────────────────────

  defp resolve_main_path(path) do
    String.replace(path, ~r/\.worktrees\/.*$/, "") |> String.trim_trailing("/")
  end

  defp read_section(context_dir, filename) do
    path = Path.join(context_dir, filename)
    if File.exists?(path), do: File.read!(path) |> String.trim()
  end

  defp read_learnings(context_dir) do
    path = Path.join(context_dir, "learnings.md")

    if File.exists?(path) do
      File.read!(path) |> split_learnings()
    else
      []
    end
  end

  defp split_learnings(content) do
    content
    |> String.split(~r/^---$/m, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn s -> s == "" or s == "# Session Learnings" end)
  end
end
