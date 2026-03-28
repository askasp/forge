defmodule Forge.ProjectScanner do
  @moduledoc """
  Scans a project directory to discover agents, skills, CLAUDE.md files,
  and existing .forge/config.toml. Used by the home page setup flow.
  """

  defstruct [
    :path,
    :name,
    :has_config,
    skills: [],
    claude_mds: [],
    config: %{}
  ]

  @doc "Scan a project directory and return what was found."
  def scan(project_path) when is_binary(project_path) do
    if File.dir?(project_path) do
      {:ok,
       %__MODULE__{
         path: project_path,
         name: Path.basename(project_path),
         has_config: File.exists?(Path.join(project_path, ".forge/config.toml")),
         skills: discover_skills(project_path),
         claude_mds: discover_claude_mds(project_path),
         config: load_existing_config(project_path)
       }}
    else
      {:error, "Not a directory"}
    end
  end

  @doc "Save configuration to .forge/config.toml"
  def save_config(project_path, config) do
    forge_dir = Path.join(project_path, ".forge")
    File.mkdir_p!(forge_dir)

    toml = build_toml(config)
    File.write!(Path.join(forge_dir, "config.toml"), toml)

    # Generate default pipeline.toml if it doesn't exist
    ensure_pipeline(forge_dir)

    :ok
  end

  @doc "Write a default pipeline.toml if one doesn't exist."
  def ensure_pipeline(forge_dir) do
    pipeline_path = Path.join(forge_dir, "pipeline.toml")

    unless File.exists?(pipeline_path) do
      File.write!(pipeline_path, Forge.Pipeline.default_toml())
    end
  end

  # ── Discovery ────────────────────────────────────────────────────

  defp discover_skills(path) do
    Path.join(path, ".claude/skills/*/SKILL.md")
    |> Path.wildcard()
    |> Enum.map(fn file ->
      name = file |> Path.dirname() |> Path.basename()
      %{name: name}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp discover_claude_mds(path) do
    [Path.join(path, "CLAUDE.md")]
    |> Kernel.++(Path.wildcard(Path.join(path, "*/CLAUDE.md")))
    |> Enum.filter(&File.exists?/1)
    |> Enum.map(&Path.relative_to(&1, path))
  end

  defp load_existing_config(path) do
    config_path = Path.join(path, ".forge/config.toml")

    if File.exists?(config_path) do
      case Toml.decode_file(config_path) do
        {:ok, config} -> config
        {:error, _} -> %{}
      end
    else
      %{}
    end
  end

  # ── TOML Generation ─────────────────────────────────────────────

  defp build_toml(config) do
    sections = [
      build_section("project", config["project"]),
      build_skills_section(config["skills"]),
      build_section("commands", config["commands"]),
      build_section("git", config["git"]),
      build_section("pr", config["pr"])
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp build_section(_name, nil), do: nil
  defp build_section(_name, map) when map_size(map) == 0, do: nil

  defp build_section(name, map) do
    lines =
      Enum.map(map, fn {k, v} ->
        "#{k} = #{quote_value(v)}"
      end)

    "[#{name}]\n#{Enum.join(lines, "\n")}\n"
  end

  defp build_skills_section(nil), do: nil

  defp build_skills_section(%{"include" => skills}) when is_list(skills) do
    items = Enum.map_join(skills, ",\n  ", &"\"#{&1}\"")
    "[skills]\ninclude = [\n  #{items}\n]\n"
  end

  defp build_skills_section(_), do: nil

  defp quote_value(v) when is_binary(v), do: "\"#{v}\""
  defp quote_value(v) when is_integer(v), do: to_string(v)
  defp quote_value(v), do: "\"#{v}\""
end
