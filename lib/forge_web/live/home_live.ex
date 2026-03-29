defmodule ForgeWeb.HomeLive do
  use ForgeWeb, :live_view

  alias Forge.{Session, ProjectScanner, KnownProjects}

  @impl true
  def mount(params, _session, socket) do
    sessions = Session.list_sessions()
    projects = group_sessions_by_project(sessions)
    known = KnownProjects.list()

    project_from_url = params["project"]

    socket =
      socket
      |> assign(:project_path, project_from_url || "")
      |> assign(:goal, "")
      |> assign(:scan, nil)
      |> assign(:sessions, sessions)
      |> assign(:projects, projects)
      |> assign(:known_projects, known)
      |> assign(:suggestions, if(project_from_url, do: [], else: known))
      |> assign(:error, nil)
      |> assign(:config_saved, false)
      |> assign(:config_collapsed, true)
      |> assign(:automation, "supervised")
      # Config form state
      |> assign(:selected_skills, [])
      |> assign(:test_command, "")
      |> assign(:dev_start, "")
      |> assign(:branch_prefix, "wt-")
      |> assign(:base_branch, "main")
      |> assign(:selected_suggestion_index, nil)
      |> assign(:mention_results, [])
      |> assign(:mention_index, 0)
      |> assign(:mention_query, nil)
      |> assign(:project_files, [])
      |> assign(:creating, false)

    if project_from_url && connected?(socket) do
      send(self(), {:do_scan, project_from_url})
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 text-base-content" id="home" phx-hook="HomeShortcuts">
      <div class="border-t-[6px] border-base-content" />

      <div class="max-w-2xl mx-auto px-8 py-16">
        <%!-- Title --%>
        <div class="flex items-baseline justify-between mb-16">
          <div>
            <h1 class="font-display text-7xl tracking-tighter leading-none mb-4">Forge</h1>
            <p class="text-base-content/40 text-sm">Iterative development workflow</p>
            <div class="mt-4 border-t-4 border-base-content w-12" />
          </div>
          <button
            id="home-theme-toggle"
            phx-hook="ThemeToggle"
            class="font-mono text-[10px] tracking-widest uppercase text-base-content/40 hover:text-base-content border-b border-transparent hover:border-base-content transition-colors duration-100 cursor-pointer"
          >
            Light / Dark
          </button>
        </div>

        <%!-- Project Path --%>
        <div class="mb-8">
          <label class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 block mb-2">
            Project Path
          </label>
          <form phx-submit="scan_project" class="flex gap-3">
            <div class="flex-1 relative" id="project-path-autocomplete" phx-hook="ProjectPathAutocomplete">
              <input
                type="text"
                name="project_path"
                value={@project_path}
                placeholder="/Users/you/git/your-project"
                phx-keyup="filter_suggestions"
                phx-blur="scan_project"
                autocomplete="off"
                class="w-full bg-transparent border-b-2 border-base-content px-0 py-3 font-mono text-sm focus:outline-none focus:border-b-4 placeholder:text-base-content/20"
              />
              <%!-- Suggestions dropdown --%>
              <div
                :if={
                  (@suggestions != [] && @project_path == "") ||
                    (@suggestions != [] && @project_path != "" && !@scan)
                }
                data-suggestions
                class="absolute top-full left-0 right-0 border border-base-content/20 bg-base-100 z-10 max-h-48 overflow-y-auto"
              >
                <button
                  :for={{path, idx} <- Enum.with_index(@suggestions)}
                  type="button"
                  phx-click="select_project"
                  phx-value-path={path}
                  data-path={path}
                  data-selected={to_string(@selected_suggestion_index == idx)}
                  class={[
                    "w-full text-left px-3 py-2 font-mono text-xs transition-colors duration-100 border-b border-base-content/5 last:border-0",
                    @selected_suggestion_index == idx && "bg-base-content text-base-100",
                    @selected_suggestion_index != idx && "hover:bg-base-content hover:text-base-100"
                  ]}
                >
                  <span class={[@selected_suggestion_index != idx && "text-base-content/40"]}>{Path.dirname(path)}/</span><span class="font-medium">{Path.basename(path)}</span>
                </button>
              </div>
            </div>
            <button
              type="submit"
              class="border-2 border-base-content px-5 py-2 font-mono text-[10px] tracking-widest uppercase hover:bg-base-content hover:text-base-100 transition-colors duration-100"
            >
              Scan
            </button>
          </form>
        </div>

        <%!-- Error --%>
        <div :if={@error} class="border-l-4 border-base-content pl-4 py-2 text-sm mb-8">
          {@error}
        </div>

        <%!-- Project Setup (after scan) --%>
        <div :if={@scan} class="mb-12">
          <div class="border-t-2 border-base-content pt-6 mb-8">
            <div class="flex items-baseline justify-between">
              <h2 class="font-display text-2xl tracking-tight">{@scan.name}</h2>
              <a
                href={~p"/project/#{URI.encode(@project_path)}"}
                class="font-mono text-[10px] tracking-widest uppercase border border-base-content px-3 py-1 hover:bg-base-content hover:text-base-100 transition-colors duration-100"
              >
                Project Settings
              </a>
            </div>
          </div>

          <%!-- Goal + Start (shown first for configured projects) --%>
          <div class={[
            @config_saved && "mb-8",
            !@config_saved && "border-t-4 border-base-content pt-8 order-last"
          ]}>
            <form phx-submit="start_session" class="space-y-6">
              <div>
                <label class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 block mb-2">
                  Task
                </label>
                <div id="goal-mention" phx-hook="MentionAutocomplete" class="relative">
                  <textarea
                    name="goal"
                    rows="3"
                    disabled={@creating}
                    placeholder="What do you want done? Use @ to reference files"
                    class="w-full bg-transparent border-2 border-base-content p-4 text-base focus:outline-none focus:border-4 placeholder:text-base-content/20 placeholder:italic resize-y"
                  >{@goal}</textarea>

                  <div
                    :if={@mention_results != []}
                    data-mention-results
                    class="absolute left-0 right-0 border border-base-content/20 bg-base-100 z-20 max-h-48 overflow-y-auto"
                    style="bottom: 100%; margin-bottom: 4px;"
                  >
                    <button
                      :for={{path, idx} <- Enum.with_index(@mention_results)}
                      type="button"
                      phx-click="mention_select_path"
                      phx-value-path={path}
                      class={[
                        "w-full text-left px-3 py-1.5 font-mono text-xs border-b border-base-content/5 last:border-0 transition-colors duration-75",
                        idx == @mention_index && "bg-base-content text-base-100",
                        idx != @mention_index && "hover:bg-base-content/10"
                      ]}
                    >
                      <span class="text-base-content/40">{Path.dirname(path)}/</span><span class="font-medium">{Path.basename(path)}</span>
                    </button>
                  </div>
                </div>
              </div>

              <%!-- Automation level --%>
              <div>
                <label class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 block mb-3">
                  Automation
                </label>
                <div class="flex gap-0">
                  <label
                    :for={
                      {level, label, desc} <- [
                        {"manual", "Manual",
                         "Human approves each phase. Stops at PR points and questions."},
                        {"supervised", "Supervised",
                         "Review the plan, then cruise. Skips PR points. Auto-resolves questions."},
                        {"autopilot", "Autopilot",
                         "Fully autonomous. Iterates until all tasks are done."}
                      ]
                    }
                    class={[
                      "flex-1 cursor-pointer border-2 px-4 py-3 transition-colors duration-100 -ml-[2px] first:ml-0",
                      @automation == level &&
                        "border-base-content bg-base-content text-base-100 z-10 relative",
                      @automation != level && "border-base-content/20 hover:border-base-content/50"
                    ]}
                  >
                    <input
                      type="radio"
                      name="automation"
                      value={level}
                      checked={@automation == level}
                      disabled={@creating}
                      phx-click="set_automation"
                      phx-value-level={level}
                      class="sr-only"
                    />
                    <div class="font-mono text-[11px] tracking-widest uppercase font-bold">
                      {label}
                    </div>
                    <div class={[
                      "text-[10px] mt-1 leading-snug",
                      @automation == level && "text-base-100/60",
                      @automation != level && "text-base-content/40"
                    ]}>
                      {desc}
                    </div>
                  </label>
                </div>
              </div>

              <button
                type="submit"
                disabled={@creating}
                class={[
                  "bg-base-content text-base-100 px-10 py-3 font-mono text-xs tracking-[0.2em] uppercase hover:bg-transparent hover:text-base-content border-2 border-base-content transition-colors duration-100",
                  @creating && "opacity-50 cursor-wait"
                ]}
              >
                {if @creating, do: "Creating...", else: "Start Session →"}
              </button>
            </form>
          </div>

          <%!-- Config summary (collapsed for returning projects) --%>
          <div
            :if={@config_saved && @config_collapsed}
            class="border-t border-base-content/10 pt-4 mb-6"
          >
            <div class="flex items-center justify-between">
              <div class="font-mono text-xs text-base-content/40 flex items-center gap-4">
                <span :if={@selected_skills != []}>{length(@selected_skills)} skills</span>
                <span :if={@test_command != ""}>{@test_command}</span>
              </div>
              <button
                phx-click="toggle_config"
                class="font-mono text-[10px] tracking-widest uppercase text-base-content/30 hover:text-base-content cursor-pointer"
              >
                Configure
              </button>
            </div>
          </div>

          <%!-- Full config form (shown for new projects or when expanded) --%>
          <div :if={!@config_saved || !@config_collapsed}>
            <%!-- What was found --%>
            <div class="grid grid-cols-2 gap-6 mb-8 text-xs">
              <div>
                <h3 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 mb-2">
                  CLAUDE.md
                </h3>
                <div :for={md <- @scan.claude_mds} class="py-0.5 font-mono">{md}</div>
              </div>
              <div>
                <h3 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 mb-2">
                  Skills ({length(@scan.skills)})
                </h3>
                <div :for={skill <- Enum.take(@scan.skills, 6)} class="py-0.5 font-mono">
                  {skill.name}
                </div>
                <div :if={length(@scan.skills) > 6} class="text-base-content/30">
                  +{length(@scan.skills) - 6} more
                </div>
              </div>
            </div>

            <%!-- Configuration form --%>
            <form phx-submit="save_config" phx-change="update_config" class="space-y-6 mb-8">
              <div class="border-t border-base-content/10 pt-6">
                <h3 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 mb-4">
                  Skills
                </h3>
                <div class="grid grid-cols-3 gap-x-4 gap-y-1">
                  <label
                    :for={skill <- @scan.skills}
                    class="flex items-center gap-2 py-1 cursor-pointer hover:text-base-content text-base-content/60 transition-colors"
                  >
                    <input
                      type="checkbox"
                      name="skills[]"
                      value={skill.name}
                      checked={skill.name in @selected_skills}
                      class="accent-current"
                    />
                    <span class="font-mono text-xs">{skill.name}</span>
                  </label>
                </div>
              </div>

              <div class="border-t border-base-content/10 pt-6">
                <h3 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 mb-4">
                  Commands
                </h3>
                <div class="space-y-3">
                  <div>
                    <label class="font-mono text-[10px] text-base-content/50 block mb-1">
                      Test command
                    </label>
                    <input
                      type="text"
                      name="test_command"
                      value={@test_command}
                      placeholder="bun test"
                      class="w-full bg-transparent border-b border-base-content/30 py-2 font-mono text-sm focus:outline-none focus:border-base-content placeholder:text-base-content/20"
                    />
                  </div>
                  <div>
                    <label class="font-mono text-[10px] text-base-content/50 block mb-1">
                      Dev start
                    </label>
                    <input
                      type="text"
                      name="dev_start"
                      value={@dev_start}
                      placeholder="./dev.sh up -d"
                      class="w-full bg-transparent border-b border-base-content/30 py-2 font-mono text-sm focus:outline-none focus:border-base-content placeholder:text-base-content/20"
                    />
                  </div>
                </div>
              </div>

              <div class="border-t border-base-content/10 pt-6">
                <h3 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 mb-4">
                  Git
                </h3>
                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <label class="font-mono text-[10px] text-base-content/50 block mb-1">
                      Branch prefix
                    </label>
                    <input
                      type="text"
                      name="branch_prefix"
                      value={@branch_prefix}
                      class="w-full bg-transparent border-b border-base-content/30 py-2 font-mono text-sm focus:outline-none focus:border-base-content"
                    />
                  </div>
                  <div>
                    <label class="font-mono text-[10px] text-base-content/50 block mb-1">
                      Base branch
                    </label>
                    <input
                      type="text"
                      name="base_branch"
                      value={@base_branch}
                      class="w-full bg-transparent border-b border-base-content/30 py-2 font-mono text-sm focus:outline-none focus:border-base-content"
                    />
                  </div>
                </div>
              </div>

              <div class="flex items-center gap-4">
                <button
                  type="submit"
                  class={[
                    "border-2 border-base-content px-8 py-2.5 font-mono text-[11px] tracking-widest uppercase transition-colors duration-100",
                    "hover:bg-base-content hover:text-base-100",
                    @config_saved && "bg-base-content text-base-100"
                  ]}
                >
                  {if @config_saved, do: "Saved", else: "Save Config"}
                </button>
                <button
                  :if={@config_saved}
                  type="button"
                  phx-click="toggle_config"
                  class="font-mono text-[10px] tracking-widest uppercase text-base-content/40 hover:text-base-content"
                >
                  Collapse
                </button>
              </div>
            </form>
          </div>
        </div>

        <%!-- Projects & Sessions --%>
        <div :if={@projects != []} class="mt-16">
          <div class="border-t border-base-content/20 mb-8" />
          <h2 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 mb-6">
            Projects
          </h2>
          <div class="space-y-8">
            <div :for={{project_path, project_sessions} <- @projects}>
              <div class="flex items-baseline justify-between mb-3">
                <a
                  href={~p"/project/#{URI.encode(project_path)}"}
                  class="font-display text-lg tracking-tight hover:opacity-60 transition-opacity"
                >
                  {Path.basename(project_path)}
                </a>
                <a
                  href={~p"/project/#{URI.encode(project_path)}"}
                  class="font-mono text-[10px] tracking-widest uppercase text-base-content/30 hover:text-base-content transition-colors"
                >
                  Settings
                </a>
              </div>
              <div class="space-y-px">
                <div
                  :for={s <- project_sessions}
                  class="flex items-center border border-base-content/10 hover:border-base-content/30 transition-colors duration-100 group"
                >
                  <a
                    href={~p"/session/#{s.id}"}
                    class="flex items-center gap-4 px-4 py-3 flex-1 min-w-0 hover:bg-base-content hover:text-base-100 transition-colors duration-100"
                  >
                    <div class={["w-1.5 h-1.5 shrink-0", session_dot(s)]} />
                    <span class="text-sm flex-1 truncate">{s.goal || "---"}</span>
                    <span class="font-mono text-[10px] text-base-content/30 group-hover:text-base-100/50">
                      {s.done}/{s.total}
                    </span>
                  </a>
                  <button
                    phx-click="delete_session"
                    phx-value-id={s.id}
                    data-confirm="Delete this session? This will remove the worktree and branch."
                    class="px-3 py-3 text-base-content/20 hover:text-error transition-colors shrink-0"
                    title="Delete session and worktree"
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="w-3.5 h-3.5"
                      viewBox="0 0 20 20"
                      fill="currentColor"
                    >
                      <path
                        fill-rule="evenodd"
                        d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Events -------------------------------------------------------

  @impl true
  def handle_event("filter_suggestions", %{"value" => query}, socket) do
    query = String.trim(query)

    suggestions =
      if query == "" do
        socket.assigns.known_projects
      else
        if String.starts_with?(query, "/") or String.starts_with?(query, "~") do
          browse_filesystem(query, socket.assigns.known_projects)
        else
          socket.assigns.known_projects
          |> Enum.filter(&String.contains?(String.downcase(&1), String.downcase(query)))
        end
      end

    {:noreply,
     assign(socket, suggestions: suggestions, project_path: query, selected_suggestion_index: nil)}
  end

  def handle_event("select_project", %{"path" => path}, socket) do
    send(self(), {:do_scan, path})
    {:noreply, assign(socket, project_path: path, suggestions: [], selected_suggestion_index: nil)}
  end

  def handle_event("navigate_suggestion", %{"direction" => direction}, socket) do
    count = length(socket.assigns.suggestions)

    if count == 0 do
      {:noreply, socket}
    else
      current = socket.assigns.selected_suggestion_index

      index =
        case {direction, current} do
          {"down", nil} -> 0
          {"down", i} -> rem(i + 1, count)
          {"up", nil} -> count - 1
          {"up", i} -> rem(i - 1 + count, count)
        end

      {:noreply, assign(socket, :selected_suggestion_index, index)}
    end
  end

  def handle_event("clear_suggestions", _params, socket) do
    {:noreply, assign(socket, suggestions: [], selected_suggestion_index: nil)}
  end

  def handle_event("scan_project", params, socket) do
    path = params["project_path"] || params["value"] || ""
    path = String.trim(path)

    if path == "" do
      {:noreply, assign(socket, scan: nil, error: nil, project_path: "")}
    else
      case ProjectScanner.scan(path) do
        {:ok, scan} ->
          config = scan.config
          skills = get_in(config, ["skills", "include"]) || Enum.map(scan.skills, & &1.name)
          test_cmd = get_in(config, ["commands", "test"]) || ""
          dev_start = get_in(config, ["commands", "dev_start"]) || ""
          branch_prefix = get_in(config, ["git", "branch_prefix"]) || "wt-"
          base_branch = get_in(config, ["git", "base_branch"]) || "main"

          KnownProjects.add(path)
          project_files = Forge.FileTree.list(path)

          {:noreply,
           socket
           |> assign(:project_path, path)
           |> assign(:scan, scan)
           |> assign(:error, nil)
           |> assign(:config_saved, scan.has_config)
           |> assign(:config_collapsed, scan.has_config)
           |> assign(:suggestions, [])
           |> assign(:known_projects, KnownProjects.list())
           |> assign(:selected_skills, skills)
           |> assign(:test_command, test_cmd)
           |> assign(:dev_start, dev_start)
           |> assign(:branch_prefix, branch_prefix)
           |> assign(:base_branch, base_branch)
           |> assign(:project_files, project_files)}

        {:error, reason} ->
          {:noreply, assign(socket, scan: nil, error: reason, project_path: path)}
      end
    end
  end

  def handle_event("toggle_config", _params, socket) do
    {:noreply, assign(socket, :config_collapsed, !socket.assigns.config_collapsed)}
  end

  def handle_event("update_config", params, socket) do
    skills = params["skills"] || []

    {:noreply,
     socket
     |> assign(:selected_skills, skills)
     |> assign(:test_command, params["test_command"] || "")
     |> assign(:dev_start, params["dev_start"] || "")
     |> assign(:branch_prefix, params["branch_prefix"] || "wt-")
     |> assign(:base_branch, params["base_branch"] || "main")}
  end

  def handle_event("save_config", params, socket) do
    skills = params["skills"] || []

    config = %{
      "project" => %{"name" => socket.assigns.scan.name},
      "skills" => %{"include" => skills},
      "commands" =>
        %{
          "test" => params["test_command"],
          "dev_start" => params["dev_start"]
        }
        |> Enum.reject(fn {_k, v} -> v == "" end)
        |> Map.new(),
      "git" => %{
        "branch_prefix" => params["branch_prefix"] || "wt-",
        "base_branch" => params["base_branch"] || "main"
      },
      "pr" => %{
        "codex_wait_minutes" => "10"
      }
    }

    ProjectScanner.save_config(socket.assigns.project_path, config)

    {:noreply,
     socket
     |> assign(:config_saved, true)
     |> assign(:selected_skills, skills)
     |> assign(:test_command, params["test_command"] || "")
     |> assign(:dev_start, params["dev_start"] || "")}
  end

  def handle_event("start_session", %{"goal" => goal}, socket) do
    goal = String.trim(goal)
    socket = assign(socket, mention_results: [], mention_index: 0, mention_query: nil)

    cond do
      socket.assigns.project_path == "" ->
        {:noreply, assign(socket, :error, "Scan a project first")}

      goal == "" ->
        {:noreply, assign(socket, :error, "Describe what you want done")}

      true ->
        if !socket.assigns.config_saved do
          # Auto-save config for new projects so the user doesn't have to click Save first
          config = %{
            "project" => %{"name" => socket.assigns.scan.name},
            "skills" => %{"include" => socket.assigns.selected_skills},
            "commands" =>
              %{"test" => socket.assigns.test_command, "dev_start" => socket.assigns.dev_start}
              |> Enum.reject(fn {_k, v} -> v == "" end)
              |> Map.new(),
            "git" => %{
              "branch_prefix" => socket.assigns.branch_prefix,
              "base_branch" => socket.assigns.base_branch
            }
          }

          ProjectScanner.save_config(socket.assigns.project_path, config)
        end

        project_path = socket.assigns.project_path
        automation = String.to_atom(socket.assigns.automation)

        {:noreply,
         socket
         |> assign(:creating, true)
         |> start_async(:create_session, fn ->
           Session.create_session(project_path, goal, automation: automation)
         end)}
    end
  end

  def handle_event("mention_search", %{"query" => query}, socket) do
    results =
      Forge.FileTree.search(
        socket.assigns.project_path,
        query,
        socket.assigns.project_files,
        15
      )

    {:noreply, assign(socket, mention_results: results, mention_index: 0, mention_query: query)}
  end

  def handle_event("mention_clear", _params, socket) do
    {:noreply, assign(socket, mention_results: [], mention_index: 0, mention_query: nil)}
  end

  def handle_event("mention_navigate", %{"direction" => dir}, socket) do
    max = length(socket.assigns.mention_results) - 1
    current = socket.assigns.mention_index

    new_index =
      case dir do
        "down" -> min(current + 1, max)
        "up" -> max(current - 1, 0)
      end

    {:noreply, assign(socket, :mention_index, new_index)}
  end

  def handle_event("mention_select", _params, socket) do
    case Enum.at(socket.assigns.mention_results, socket.assigns.mention_index) do
      nil ->
        {:noreply, socket}

      path ->
        {:noreply,
         socket
         |> assign(mention_results: [], mention_index: 0, mention_query: nil)
         |> push_event("mention_selected", %{text: path})}
    end
  end

  def handle_event("mention_select_path", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(mention_results: [], mention_index: 0, mention_query: nil)
     |> push_event("mention_selected", %{text: path})}
  end

  def handle_event("set_automation", %{"level" => level}, socket) do
    {:noreply, assign(socket, :automation, level)}
  end

  def handle_event("delete_session", %{"id" => session_id}, socket) do
    Session.delete_session(session_id)
    sessions = Session.list_sessions()
    projects = group_sessions_by_project(sessions)
    {:noreply, assign(socket, sessions: sessions, projects: projects)}
  end

  # -- Async handlers -----------------------------------------------

  @impl true
  def handle_async(:create_session, {:ok, {:ok, session_id}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/session/#{session_id}")}
  end

  def handle_async(:create_session, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, error: "Failed: #{reason}", creating: false)}
  end

  def handle_async(:create_session, {:exit, _reason}, socket) do
    {:noreply, assign(socket, error: "Session creation failed unexpectedly", creating: false)}
  end

  # -- Info handlers ------------------------------------------------

  @impl true
  def handle_info({:do_scan, path}, socket) do
    case ProjectScanner.scan(path) do
      {:ok, scan} ->
        config = scan.config
        KnownProjects.add(path)
        project_files = Forge.FileTree.list(path)

        {:noreply,
         socket
         |> assign(:project_path, path)
         |> assign(:scan, scan)
         |> assign(:error, nil)
         |> assign(:config_saved, scan.has_config)
         |> assign(:config_collapsed, scan.has_config)
         |> assign(:suggestions, [])
         |> assign(:known_projects, KnownProjects.list())
         |> assign(
           :selected_skills,
           get_in(config, ["skills", "include"]) || Enum.map(scan.skills, & &1.name)
         )
         |> assign(:test_command, get_in(config, ["commands", "test"]) || "")
         |> assign(:dev_start, get_in(config, ["commands", "dev_start"]) || "")
         |> assign(:branch_prefix, get_in(config, ["git", "branch_prefix"]) || "wt-")
         |> assign(:base_branch, get_in(config, ["git", "base_branch"]) || "main")
         |> assign(:project_files, project_files)}

      {:error, reason} ->
        {:noreply, assign(socket, scan: nil, error: reason, project_path: path)}
    end
  end

  # -- Helpers ------------------------------------------------------

  defp group_sessions_by_project(sessions) do
    sessions
    |> Enum.filter(fn s -> s.repo_path end)
    |> Enum.group_by(fn s -> s.repo_path end)
    |> Enum.sort_by(fn {path, _} -> path end)
  end

  defp browse_filesystem(query, known_projects) do
    expanded = expand_home(query)

    {parent, prefix} =
      if String.ends_with?(expanded, "/") do
        {expanded, ""}
      else
        {Path.dirname(expanded), Path.basename(expanded)}
      end

    matching_known =
      known_projects
      |> Enum.filter(&String.contains?(String.downcase(&1), String.downcase(query)))

    fs_entries =
      case File.ls(parent) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn entry ->
            full = Path.join(parent, entry)

            File.dir?(full) &&
              !String.starts_with?(entry, ".") &&
              (prefix == "" || String.starts_with?(String.downcase(entry), String.downcase(prefix)))
          end)
          |> Enum.sort()
          |> Enum.map(&Path.join(parent, &1))

        {:error, _} ->
          []
      end

    known_set = MapSet.new(matching_known)
    unique_fs = Enum.reject(fs_entries, &MapSet.member?(known_set, &1))

    (matching_known ++ unique_fs)
    |> Enum.take(20)
  end

  defp expand_home(path) do
    case path do
      "~" -> System.user_home!()
      "~/" <> rest -> Path.join(System.user_home!(), rest)
      other -> other
    end
  end

  defp session_dot(s) do
    cond do
      s.done == s.total and s.total > 0 -> "bg-base-content"
      s.done > 0 -> "bg-base-content/50 animate-pulse"
      true -> "border border-base-content/30"
    end
  end
end
