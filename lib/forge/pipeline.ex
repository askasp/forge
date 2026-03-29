defmodule Forge.Pipeline do
  @moduledoc """
  Pipeline definition: an ordered list of stage templates and transition rules.
  Loaded from .forge/pipeline.toml per project, or falls back to a built-in default.

  The pipeline tells the orchestrator what happens after each role completes:
  - on_success: which stage runs next
  - on_failure: what to do when the agent reports issues

  Fix cycles are explicit per stage:
  - on_failure = "fix_cycle" means: create a FIX @{fix_role} step + Re-run @{this role} step
  - fix_role says who writes the fix (usually "dev")
  - max_cycles limits how many times the loop can repeat before stopping

  Users customize the workflow by editing .forge/pipeline.toml.
  """

  defmodule Stage do
    @moduledoc false
    defstruct [
      :id,
      :role,
      on_success: :next,
      on_failure: :stop,
      fix_role: :dev,
      max_cycles: 3,
      optional: false
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            role: atom(),
            on_success: :next | :done | String.t(),
            on_failure: :stop | :fix_cycle,
            fix_role: atom(),
            max_cycles: non_neg_integer(),
            optional: boolean()
          }
  end

  defstruct stages: []

  @type t :: %__MODULE__{
          stages: [Stage.t()]
        }

  # ── Loading ────────────────────────────────────────────────────

  @doc "Load pipeline from .forge/pipeline.toml, falling back to the built-in default."
  def load(project_path) do
    # Resolve to main project path (not worktree)
    main_path =
      project_path
      |> String.replace(~r/\.worktrees\/.*$/, "")
      |> String.trim_trailing("/")

    pipeline_path = Path.join(main_path, ".forge/pipeline.toml")

    if File.exists?(pipeline_path) do
      case Toml.decode_file(pipeline_path) do
        {:ok, config} -> from_toml(config)
        {:error, _} -> default()
      end
    else
      default()
    end
  end

  @doc "Built-in default pipeline: dev → qa → review → human."
  def default do
    %__MODULE__{
      stages: [
        %Stage{id: "dev", role: :dev, on_success: "qa"},
        %Stage{
          id: "qa",
          role: :qa,
          on_success: "review",
          on_failure: :fix_cycle,
          fix_role: :dev,
          max_cycles: 3
        },
        %Stage{
          id: "review",
          role: :reviewer,
          on_success: :next,
          on_failure: :fix_cycle,
          fix_role: :dev,
          max_cycles: 2
        },
        %Stage{id: "human", role: :human, on_success: :next, optional: true}
      ]
    }
  end

  @doc "Find the pipeline stage definition for a given role."
  def stage_for_role(%__MODULE__{stages: stages}, role) when is_atom(role) do
    Enum.find(stages, fn s -> s.role == role end)
  end

  def stage_for_role(_, _), do: nil

  @doc "Find a pipeline stage by its string ID."
  def stage_by_id(%__MODULE__{stages: stages}, id) when is_binary(id) do
    Enum.find(stages, fn s -> s.id == id end)
  end

  def stage_by_id(_, _), do: nil

  @doc "Get the max fix cycles for a stage by its role."
  def max_cycles(%__MODULE__{} = pipeline, role) do
    case stage_for_role(pipeline, role) do
      %Stage{max_cycles: n} -> n
      _ -> 3
    end
  end

  @doc "Get the fix role for a stage — who writes the fix when this stage finds issues."
  def fix_role(%__MODULE__{} = pipeline, role) do
    case stage_for_role(pipeline, role) do
      %Stage{fix_role: fr} -> fr
      _ -> :dev
    end
  end

  @doc "Check if a role has fix_cycle behavior on failure."
  def fix_cycle?(%__MODULE__{} = pipeline, role) do
    case stage_for_role(pipeline, role) do
      %Stage{on_failure: :fix_cycle} -> true
      _ -> false
    end
  end

  @doc "Check if a role exists in the pipeline."
  def has_role?(%__MODULE__{stages: stages}, role) do
    Enum.any?(stages, fn s -> s.role == role end)
  end

  @doc "Initialize cycle counters for all fix_cycle stages (e.g., %{qa: 0, reviewer: 0})."
  def init_cycle_counts(%__MODULE__{stages: stages}) do
    stages
    |> Enum.filter(fn s -> s.on_failure == :fix_cycle end)
    |> Map.new(fn s -> {s.role, 0} end)
  end

  # ── TOML Parsing ───────────────────────────────────────────────

  defp from_toml(config) do
    stages =
      (config["stage"] || [])
      |> Enum.map(fn s ->
        %Stage{
          id: s["id"],
          role: safe_to_atom(s["role"]),
          on_success: parse_transition(s["on_success"] || "next"),
          on_failure: parse_transition(s["on_failure"] || "stop"),
          fix_role: safe_to_atom(s["fix_role"] || "dev"),
          max_cycles: s["max_cycles"] || 3,
          optional: s["optional"] || false
        }
      end)

    %__MODULE__{stages: stages}
  end

  defp parse_transition("next"), do: :next
  defp parse_transition("done"), do: :done
  defp parse_transition("stop"), do: :stop
  defp parse_transition("fix_cycle"), do: :fix_cycle
  defp parse_transition(stage_id) when is_binary(stage_id), do: stage_id

  @known_atoms ~w(dev qa reviewer human planner)a

  defp safe_to_atom(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @known_atoms, do: atom, else: raise "Unknown role in pipeline: #{str}"
  rescue
    ArgumentError -> raise "Unknown role in pipeline: #{str}"
  end

  # ── Default TOML generation ────────────────────────────────────

  @doc "Return the default pipeline as a TOML string, for generating .forge/pipeline.toml."
  def default_toml do
    """
    # Forge Pipeline — defines the workflow stages and transitions.
    #
    # Each [[stage]] is dispatched by role based on task dependencies.
    # The pipeline controls what happens AFTER each role completes.
    #
    # Transitions (on_success / on_failure):
    #   "next"       — continue to the next task
    #   "fix_cycle"  — agent inserts FIX @{fix_role} + Re-run @{this role} steps
    #   "stop"       — pause and wait for human intervention
    #   "<stage_id>" — jump to a specific stage
    #
    # Fix cycles:
    #   When a QA or review agent finds issues (VERDICT: NEEDS_FIXES), it creates:
    #     1. A FIX step assigned to fix_role (usually @dev)
    #     2. A Re-run step assigned to itself (to verify the fix)
    #   This loops up to max_cycles times before the orchestrator stops.
    #
    # To disable code review: remove the [[stage]] id = "review" block.
    # To change who fixes review issues: set fix_role = "senior_dev" on the review stage.
    # To allow more QA retries: increase max_cycles on the qa stage.

    #───────────────────────────────────────────────────────────────
    # Stage 1: Dev implements the task
    #───────────────────────────────────────────────────────────────
    [[stage]]
    id = "dev"
    role = "dev"
    on_success = "qa"           # after dev → QA tests it

    #───────────────────────────────────────────────────────────────
    # Stage 2: QA tests the implementation
    #   On NEEDS_FIXES: dev fixes → QA re-runs (up to 3 times)
    #───────────────────────────────────────────────────────────────
    [[stage]]
    id = "qa"
    role = "qa"
    on_success = "review"       # after QA passes → reviewer checks code
    on_failure = "fix_cycle"    # NEEDS_FIXES → FIX @dev + Re-run @qa
    fix_role = "dev"            # who writes the fix
    max_cycles = 3              # max QA ↔ dev iterations

    #───────────────────────────────────────────────────────────────
    # Stage 3: Code review checks quality
    #   On findings: dev fixes → reviewer re-checks (up to 2 times)
    #───────────────────────────────────────────────────────────────
    [[stage]]
    id = "review"
    role = "reviewer"
    on_success = "next"         # LGTM → continue to next step or PR point
    on_failure = "fix_cycle"    # findings → FIX @dev + Re-run @reviewer
    fix_role = "dev"            # who writes the fix
    max_cycles = 2              # max review ↔ dev iterations

    #───────────────────────────────────────────────────────────────
    # Stage 4: Human checkpoint (optional)
    #   Skipped in autopilot mode.
    #───────────────────────────────────────────────────────────────
    [[stage]]
    id = "human"
    role = "human"
    optional = true             # skipped in autopilot mode
    """
  end
end
