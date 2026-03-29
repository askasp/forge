# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Forge

Forge is an AI agent orchestration platform built with Phoenix/Elixir. It manages multi-step development workflows where agents (Planner, Dev, QA, Reviewer, Human) collaborate through a configurable pipeline. Sessions create isolated git worktrees, and agents tackle tasks sequentially with real-time monitoring via LiveView.

## Commands

```bash
mix setup                # Install deps, create DB, build assets
mix phx.server           # Dev server at http://localhost:4000
mix test                 # Run all tests
mix test test/path.exs   # Run a single test file
mix test --failed        # Re-run previously failed tests
mix format               # Format code
mix precommit            # compile --warning-as-errors + deps.unlock --unused + format + test
mix ecto.migrate         # Run pending migrations
mix ecto.reset           # Drop + recreate + migrate DB
```

The `precommit` alias runs in the `:test` environment (see `cli/0` in mix.exs).

## Database

PostgreSQL on port **5433** (not the default 5432). Database names: `forge_dev`, `forge_test`.

## Architecture

### Supervision Tree

`Forge.Application` starts: Repo, Telemetry, PubSub (`Forge.PubSub`), `Forge.SessionRegistry` (unique Registry), `Forge.SessionSupervisor` (DynamicSupervisor), and the Phoenix Endpoint. On startup, `Forge.Session.restore_sessions/0` restores active sessions.

### Session Lifecycle (`Forge.Session`)

1. **Create** -- loads project config from `.forge/config.toml`, creates/reuses a git worktree, inserts DB record, starts per-session processes (Scheduler + AgentRunner), creates initial planner task
2. **Restore** -- on app boot, restores active sessions from DB
3. **Merge** -- merges worktree branch to main, cleans up, marks complete
4. **Delete** -- removes worktree and DB records

Each session is supervised by `Forge.Session.Supervisor` which manages a `Forge.Scheduler` and `Forge.Session.AgentRunner`.

### Task Pipeline (`Forge.Pipeline`)

Default flow: **Planner -> Dev -> QA -> Reviewer -> Human**. Each stage has `on_success` (next stage or done), `on_failure` (stop or fix_cycle), `fix_role`, and `max_cycles`. Customizable per project via `.forge/pipeline.toml`.

### Key Modules

- **`Forge.Scheduler`** -- per-session GenServer that dispatches agents for ready tasks, handles pipeline transitions and fix cycles, enforces concurrency and automation level. Subscribes to PubSub for task events.
- **`Forge.Session.AgentRunner`** -- GenServer that spawns `claude -p` CLI processes, streams JSON output to LiveView via PubSub, handles timeouts (5 min inactivity, 30 min total).
- **`Forge.TaskEngine`** -- task CRUD, state transitions, dependency queries, agent run tracking, PubSub broadcasting.
- **`Forge.PromptBuilder`** -- constructs agent prompts from role conventions, project context, task description, available skills, and MCP tool definitions.
- **`Forge.ProjectContext`** -- persistent project memory stored in `.forge/context/` (architecture.md, key_files.md, learnings.md).
- **`Forge.Project`** -- loads project config from `.forge/config.toml`.

### Schemas (all use binary_id primary keys)

- **projects** -- name, repo_path, pipeline_config
- **sessions** -- project_id, worktree_path, goal, state (active|paused|complete), automation (manual|supervised|autopilot), plan_markdown
- **tasks** -- session_id, parent_task_id, depends_on_id, role, state (planned|assigned|in_progress|done|failed), title, prompt, result (JSON), iteration_count, acceptance_criteria
- **agent_runs** -- task_id, role, output, exit_code, started_at, finished_at
- **images** -- task_id, name, url

### Web Layer

Routes are in `ForgeWeb.Router`. Key LiveViews:
- **HomeLive** (`/`) -- session list, create new session
- **DashboardLive** (`/session/:id`) -- real-time task monitoring, output streaming, controls
- **ProjectLive** (`/project/:path`) -- project details

MCP API at `/api/mcp/*` exposes tools for agents (project info, context updates, screenshots).

### Frontend

- Tailwind v4 (no tailwind.config.js, uses `@import "tailwindcss"` syntax in app.css)
- esbuild for JS bundling
- LiveView JS hooks in `assets/js/hooks/` (auto_scroll, keyboard_shortcuts, mention_autocomplete, theme_toggle)
- MCP server adapter: `bin/forge-mcp`

## Key Conventions

See `AGENTS.md` for full Phoenix/Elixir/LiveView guidelines. The critical ones:

- **Req for HTTP** -- never use httpoison, tesla, or httpc
- **Streams for collections** -- always use LiveView streams, never assign lists
- **Forms via `to_form/2`** -- never pass changesets directly to templates
- **`<.input>` component** -- always use the imported component for form inputs
- **No nested modules** in the same file (causes cyclic deps)
- **No `@apply`** in CSS -- write custom classes directly
- **No inline `<script>` tags** -- use hooks in `assets/js/`
