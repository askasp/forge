defmodule Forge.DiffParser do
  @moduledoc """
  Parses unified git diff output into structured data for rendering.
  """

  defmodule FileDiff do
    defstruct [:path, :old_path, :status, lines: [], stats: {0, 0}]
  end

  defmodule Line do
    defstruct [:type, :old_num, :new_num, :content]
    # type: :context, :add, :remove, :hunk_header
  end

  @doc "Parse `git diff` output into a list of FileDiff structs."
  def parse(diff_text) when is_binary(diff_text) do
    diff_text
    |> String.split("\n")
    |> chunk_by_file()
    |> Enum.map(&parse_file_diff/1)
  end

  @doc "Get diff for a specific commit in a repo."
  def diff_for_commit(workdir, commit_hash) do
    case System.cmd("git", ["diff", "#{commit_hash}~1..#{commit_hash}"],
           cd: workdir, stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      {output, _} -> [{:error, output}]
    end
  end

  @doc "Get diff between HEAD and N commits back."
  def diff_head(workdir, n \\ 1) do
    case System.cmd("git", ["diff", "HEAD~#{n}..HEAD"],
           cd: workdir, stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      {output, _} -> [{:error, output}]
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp chunk_by_file(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      if String.starts_with?(line, "diff --git") do
        [[line] | acc]
      else
        case acc do
          [current | rest] -> [[line | current] | rest]
          [] -> [[line]]
        end
      end
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.reject(fn lines -> lines == [""] end)
  end

  defp parse_file_diff(lines) do
    {path, old_path, status} = extract_file_info(lines)
    {parsed_lines, adds, removes} = parse_diff_lines(lines)

    %FileDiff{
      path: path,
      old_path: old_path,
      status: status,
      lines: parsed_lines,
      stats: {adds, removes}
    }
  end

  defp extract_file_info(lines) do
    diff_line = Enum.find(lines, &String.starts_with?(&1, "diff --git"))

    path =
      case Regex.run(~r/diff --git a\/.+ b\/(.+)/, diff_line || "") do
        [_, p] -> p
        _ -> "unknown"
      end

    status =
      cond do
        Enum.any?(lines, &String.starts_with?(&1, "new file")) -> :added
        Enum.any?(lines, &String.starts_with?(&1, "deleted file")) -> :deleted
        Enum.any?(lines, &String.starts_with?(&1, "rename")) -> :renamed
        true -> :modified
      end

    old_path =
      case Regex.run(~r/rename from (.+)/, Enum.join(lines, "\n")) do
        [_, p] -> p
        _ -> nil
      end

    {path, old_path, status}
  end

  defp parse_diff_lines(lines) do
    {parsed, _old_num, _new_num, adds, removes} =
      lines
      |> Enum.reduce({[], 0, 0, 0, 0}, fn line, {acc, old_n, new_n, a, r} ->
        cond do
          String.starts_with?(line, "@@") ->
            {old_start, new_start} = parse_hunk_header(line)

            header = %Line{
              type: :hunk_header,
              old_num: nil,
              new_num: nil,
              content: line
            }

            {[header | acc], old_start, new_start, a, r}

          String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
            l = %Line{type: :add, old_num: nil, new_num: new_n, content: String.slice(line, 1..-1//1)}
            {[l | acc], old_n, new_n + 1, a + 1, r}

          String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
            l = %Line{type: :remove, old_num: old_n, new_num: nil, content: String.slice(line, 1..-1//1)}
            {[l | acc], old_n + 1, new_n, a, r + 1}

          String.starts_with?(line, " ") ->
            l = %Line{type: :context, old_num: old_n, new_num: new_n, content: String.slice(line, 1..-1//1)}
            {[l | acc], old_n + 1, new_n + 1, a, r}

          true ->
            {acc, old_n, new_n, a, r}
        end
      end)

    {Enum.reverse(parsed), adds, removes}
  end

  defp parse_hunk_header(line) do
    case Regex.run(~r/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
      [_, old_start, new_start] ->
        {String.to_integer(old_start), String.to_integer(new_start)}

      _ ->
        {1, 1}
    end
  end
end
