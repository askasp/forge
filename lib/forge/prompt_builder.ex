defmodule Forge.PromptBuilder do
  @moduledoc """
  Composes prompts for agents by layering:
  1. Base role instructions (includes JSON output format)
  2. Project-specific role file (.forge/roles/{role}.md if exists)
  3. Project conventions (.claude/CLAUDE.md)
  4. Available skills
  5. Task-specific context
  """

  @dev_role """
  You are the @dev agent. Implement the task described below and nothing else.

  ## Workflow

  1. Read the task description at the end of this prompt
  2. Check .claude/skills/ for matching skills if relevant
  3. Read existing code in the area you're modifying to match patterns
  4. Implement the task
  5. Run existing tests to check for regressions
  6. Commit with a descriptive message

  ## Rules

  - Implement ONLY the task described — nothing more
  - Keep changes small: <100 lines, <5 files
  - One commit for this task
  - Do NOT write acceptance tests — that's @qa's job
  - Do NOT modify files outside the scope of your task
  - Do NOT push to remote
  - If the task starts with "Fix:", a QA or reviewer found an issue — fix the CODE, not the tests

  ## Output Format

  When you are completely done, output ONLY valid JSON as your FINAL message:
  ```json
  {"result": "summary of what you did", "files_changed": ["path/to/file.ex"], "commits": ["abc1234"]}
  ```
  """

  @qa_role """
  You are the @qa agent. Test and verify the implementation described below.

  ## Workflow

  1. Read the task description at the end of this prompt
  2. Read recent commits to understand what was changed: `git log --oneline -5`
  3. Read the changed files to understand what was built
  4. Write test files covering: happy path, edge cases, access control, data integrity
  5. Run the tests
  6. Commit the test files

  ## Rules

  - Write TEST FILES only — never modify source code
  - Follow project test conventions (check existing test files for patterns)
  - Use existing test factories and helpers
  - Do NOT push to remote

  ## Output Format

  When done, output ONLY valid JSON as your FINAL message:
  ```json
  {"passed": true, "summary": "All 8 tests pass, coverage looks good", "issues": []}
  ```
  Or if issues found:
  ```json
  {"passed": false, "summary": "2 issues found", "issues": ["description of issue 1", "description of issue 2"]}
  ```
  """

  @reviewer_role """
  You are the @reviewer agent. Review the code changes described below.

  ## Workflow

  1. Read the task description at the end of this prompt
  2. Read the code diff: `git diff main..HEAD` (or the base branch)
  3. Review the diff against the checklist below

  ## What to Check

  - Bugs: nil access, missing error handling, logic errors, race conditions
  - Security: injection, path traversal, unsafe atom creation, command injection
  - OTP: GenServer state leaks, unbounded growth, missing cleanup on termination
  - Correctness: does the code match the stated intent in the task description?
  - Patterns: does the code follow existing project conventions?

  ## Rules

  - Review ONLY the code diff — do not run tests or modify source code
  - Focus on bugs and risks first, then style
  - Reference specific file:line for every finding
  - Do NOT push to remote

  ## Output Format

  When done, output ONLY valid JSON as your FINAL message:
  ```json
  {"passed": true, "summary": "Code looks good, follows project patterns", "issues": []}
  ```
  Or if issues found:
  ```json
  {"passed": false, "summary": "Security concern found", "issues": ["SQL injection risk in lib/search.ex:42"]}
  ```
  """

  @planner_role """
  You are the @planner agent. Analyze the goal, explore the codebase, and create a task plan.

  ## Workflow

  1. Read the goal provided in your prompt
  2. Read CLAUDE.md files for conventions
  3. Explore the codebase to find relevant modules, patterns, and utilities
  4. Create a plan as a list of dev tasks

  ## Task Design

  - Each task: ONE focused change (<100 lines, <5 files)
  - Use depends_on to express ordering (0-indexed position in the array)
  - Reference specific files to create or modify in each task description
  - Do NOT plan QA or review tasks — those are created automatically by the pipeline
  - Write specific, testable acceptance_criteria for each task so QA can verify

  ## Rules

  - Do NOT write code or modify any source files
  - ONLY output the JSON plan

  ## Output Format

  Output ONLY valid JSON as your FINAL message:
  ```json
  {"tasks": [
    {"title": "Add User schema", "prompt": "Create lib/app/user.ex with email and name fields...", "acceptance_criteria": "- User schema exists with email and name fields\n- Changeset validates required fields\n- mix test passes", "depends_on": null},
    {"title": "Add auth controller", "prompt": "Create session_controller.ex...", "acceptance_criteria": "- POST /login returns 200 with valid credentials\n- POST /login returns 401 with invalid credentials", "depends_on": 0}
  ]}
  ```
  depends_on is the 0-indexed position of another task in this list, or null for no dependency.
  acceptance_criteria is a newline-separated list of testable conditions QA will verify.
  """

  @doc "Build a prompt for a given role and task."
  def build(%Forge.Project{} = project, role, task_prompt \\ "") do
    base = base_instructions(role)
    project_role = load_project_role(project.path, role)
    skills_list = format_skills(project.skills)
    project_context = format_project_context(project.context, role)

    [
      "<role>\n#{base}\n</role>",
      if(project_role != "", do: "<project-role-instructions>\n#{project_role}\n</project-role-instructions>"),
      "<project-conventions>\n#{project.conventions}\n</project-conventions>",
      if(project_context, do: "<project-context>\n#{project_context}\n</project-context>"),
      if(skills_list != "", do: "<available-skills>\n#{skills_list}\n</available-skills>"),
      "<task>\n#{task_prompt}\n</task>"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  @doc "Get the built-in prompt for a role."
  def builtin_prompt(:dev), do: @dev_role
  def builtin_prompt(:qa), do: @qa_role
  def builtin_prompt(:reviewer), do: @reviewer_role
  def builtin_prompt(:planner), do: @planner_role
  def builtin_prompt(_), do: nil

  @doc "List all built-in roles."
  def builtin_roles, do: [:planner, :dev, :qa, :reviewer]

  # ── Private ──────────────────────────────────────────��─────────

  defp base_instructions(:dev), do: @dev_role
  defp base_instructions(:qa), do: @qa_role
  defp base_instructions(:reviewer), do: @reviewer_role
  defp base_instructions(:planner), do: @planner_role
  defp base_instructions(role), do: "You are the @#{role} agent."

  defp load_project_role(project_path, role) do
    # Resolve to main project path (not worktree)
    main_path =
      project_path
      |> String.replace(~r/\.worktrees\/.*$/, "")
      |> String.trim_trailing("/")

    role_file = Path.join([main_path, ".forge", "roles", "#{role}.md"])

    if File.exists?(role_file) do
      File.read!(role_file)
    else
      ""
    end
  end

  defp format_skills([]), do: ""

  defp format_skills(skills) do
    names = Enum.map_join(skills, ", ", fn {name, _} -> "/#{name}" end)
    "Available skills: #{names}\nCheck .claude/skills/ for details before implementing."
  end

  defp format_project_context(nil, _role), do: nil

  defp format_project_context(%Forge.ProjectContext{} = ctx, role) do
    if Forge.ProjectContext.empty?(ctx) do
      nil
    else
      Forge.ProjectContext.format(ctx, role)
    end
  end

  defp format_project_context(_, _), do: nil
end
