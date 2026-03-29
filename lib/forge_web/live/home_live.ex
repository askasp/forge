defmodule ForgeWeb.HomeLive do
  use ForgeWeb, :live_view

  alias Forge.{Session, KnownProjects}

  @impl true
  def mount(_params, _session, socket) do
    sessions = Session.list_sessions()
    projects = group_sessions_by_project(sessions)
    known = KnownProjects.list()

    # Default to the most recently used project
    default_project = List.first(known) || ""

    socket =
      socket
      |> assign(:project_path, default_project)
      |> assign(:goal, "")
      |> assign(:known_projects, known)
      |> assign(:sessions, sessions)
      |> assign(:projects, projects)
      |> assign(:error, nil)
      |> assign(:automation, "supervised")
      |> assign(:creating, false)
      |> assign(:mention_results, [])
      |> assign(:mention_index, 0)
      |> assign(:mention_query, nil)
      |> assign(:project_files, load_project_files(default_project))
      |> assign(:adding_project, false)
      |> assign(:new_project_path, "")
      |> assign(:suggestions, [])

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

        <%!-- New Session --%>
        <div class="mb-16">
          <form phx-submit="start_session" class="space-y-6">
            <%!-- Project selector --%>
            <div>
              <label class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 block mb-2">
                Project
              </label>
              <div class="flex gap-3 items-center">
                <select
                  :if={@known_projects != [] && !@adding_project}
                  name="project_path"
                  phx-change="select_project"
                  class="flex-1 bg-transparent border-b-2 border-base-content px-0 py-3 font-mono text-sm focus:outline-none cursor-pointer appearance-none"
                >
                  <option
                    :for={path <- @known_projects}
                    value={path}
                    selected={path == @project_path}
                  >
                    {Path.basename(path)}
                    <span class="text-base-content/30"> — {Path.dirname(path)}</span>
                  </option>
                </select>
                <div :if={@known_projects == [] || @adding_project} class="flex-1 relative" id="project-path-autocomplete" phx-hook="ProjectPathAutocomplete">
                  <input
                    type="text"
                    name="new_project_path"
                    value={@new_project_path}
                    placeholder="/path/to/your-project"
                    phx-keyup="filter_suggestions"
                    autocomplete="off"
                    class="w-full bg-transparent border-b-2 border-base-content px-0 py-3 font-mono text-sm focus:outline-none placeholder:text-base-content/20"
                  />
                  <%!-- Filesystem suggestions --%>
                  <div
                    :if={@suggestions != []}
                    data-suggestions
                    class="absolute top-full left-0 right-0 border border-base-content/20 bg-base-100 z-10 max-h-48 overflow-y-auto"
                  >
                    <button
                      :for={path <- @suggestions}
                      type="button"
                      phx-click="add_project"
                      phx-value-path={path}
                      class="w-full text-left px-3 py-2 font-mono text-xs hover:bg-base-content hover:text-base-100 transition-colors duration-100 border-b border-base-content/5 last:border-0"
                    >
                      <span class="text-base-content/40">{Path.dirname(path)}/</span><span class="font-medium">{Path.basename(path)}</span>
                    </button>
                  </div>
                </div>
                <button
                  :if={!@adding_project && @known_projects != []}
                  type="button"
                  phx-click="toggle_add_project"
                  class="font-mono text-[10px] tracking-widest uppercase text-base-content/30 hover:text-base-content border-b border-transparent hover:border-base-content transition-colors shrink-0"
                >
                  + Add
                </button>
                <button
                  :if={@adding_project}
                  type="button"
                  phx-click="add_project"
                  phx-value-path={@new_project_path}
                  class="border-2 border-base-content px-4 py-2 font-mono text-[10px] tracking-widest uppercase hover:bg-base-content hover:text-base-100 transition-colors duration-100 shrink-0"
                >
                  Add
                </button>
                <button
                  :if={@adding_project}
                  type="button"
                  phx-click="toggle_add_project"
                  class="font-mono text-[10px] text-base-content/30 hover:text-base-content shrink-0"
                >
                  Cancel
                </button>
              </div>
            </div>

            <%!-- Goal --%>
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
                      {"manual", "Manual", "Approve each phase"},
                      {"supervised", "Supervised", "Review plan, then auto"},
                      {"autopilot", "Autopilot", "Fully autonomous"}
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

            <%!-- Error --%>
            <div :if={@error} class="border-l-4 border-base-content pl-4 py-2 text-sm">
              {@error}
            </div>

            <button
              type="submit"
              disabled={@creating}
              class={[
                "bg-base-content text-base-100 px-10 py-3 font-mono text-xs tracking-[0.2em] uppercase hover:bg-transparent hover:text-base-content border-2 border-base-content transition-colors duration-100",
                @creating && "opacity-50 cursor-wait"
              ]}
            >
              {if @creating, do: "Creating...", else: "Start Session"}
            </button>
          </form>
        </div>

        <%!-- Active Sessions --%>
        <div :if={@projects != []} class="mt-8">
          <div class="border-t border-base-content/20 mb-8" />
          <h2 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 mb-6">
            Active Sessions
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
  def handle_event("select_project", %{"project_path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:project_path, path)
     |> assign(:project_files, load_project_files(path))}
  end

  def handle_event("toggle_add_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:adding_project, !socket.assigns.adding_project)
     |> assign(:new_project_path, "")
     |> assign(:suggestions, [])}
  end

  def handle_event("filter_suggestions", %{"value" => query}, socket) do
    query = String.trim(query)

    suggestions =
      if query == "" do
        []
      else
        if String.starts_with?(query, "/") or String.starts_with?(query, "~") do
          browse_filesystem(query)
        else
          socket.assigns.known_projects
          |> Enum.filter(&String.contains?(String.downcase(&1), String.downcase(query)))
        end
      end

    {:noreply, assign(socket, suggestions: suggestions, new_project_path: query)}
  end

  def handle_event("add_project", %{"path" => path}, socket) do
    path = String.trim(path)

    if path != "" and File.dir?(path) do
      # Scan to validate it's a valid project, then auto-save config if needed
      case Forge.ProjectScanner.scan(path) do
        {:ok, scan} ->
          unless scan.has_config do
            # Auto-create default config
            config = %{
              "project" => %{"name" => scan.name},
              "skills" => %{"include" => Enum.map(scan.skills, & &1.name)},
              "commands" => %{},
              "git" => %{"branch_prefix" => "wt-", "base_branch" => "main"}
            }

            Forge.ProjectScanner.save_config(path, config)
          end

          KnownProjects.add(path)

          {:noreply,
           socket
           |> assign(:known_projects, KnownProjects.list())
           |> assign(:project_path, path)
           |> assign(:adding_project, false)
           |> assign(:new_project_path, "")
           |> assign(:suggestions, [])
           |> assign(:project_files, load_project_files(path))}

        {:error, reason} ->
          {:noreply, assign(socket, :error, reason)}
      end
    else
      {:noreply, assign(socket, :error, "Directory not found: #{path}")}
    end
  end

  def handle_event("start_session", %{"goal" => goal} = params, socket) do
    goal = String.trim(goal)
    project_path = params["project_path"] || socket.assigns.project_path
    socket = assign(socket, mention_results: [], mention_index: 0, mention_query: nil)

    cond do
      project_path == "" ->
        {:noreply, assign(socket, :error, "Select a project first")}

      goal == "" ->
        {:noreply, assign(socket, :error, "Describe what you want done")}

      true ->
        automation = String.to_atom(socket.assigns.automation)

        {:noreply,
         socket
         |> assign(:creating, true)
         |> assign(:error, nil)
         |> start_async(:create_session, fn ->
           Session.create_session(project_path, goal, automation: automation)
         end)}
    end
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

  # Mention autocomplete handlers (for @file references in goal)
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

  # -- Helpers ------------------------------------------------------

  defp load_project_files(""), do: []

  defp load_project_files(path) do
    if File.dir?(path), do: Forge.FileTree.list(path), else: []
  end

  defp group_sessions_by_project(sessions) do
    sessions
    |> Enum.filter(fn s -> s.repo_path end)
    |> Enum.group_by(fn s -> s.repo_path end)
    |> Enum.sort_by(fn {path, _} -> path end)
  end

  defp browse_filesystem(query) do
    expanded = expand_home(query)

    {parent, prefix} =
      if String.ends_with?(expanded, "/") do
        {expanded, ""}
      else
        {Path.dirname(expanded), Path.basename(expanded)}
      end

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
        |> Enum.take(20)

      {:error, _} ->
        []
    end
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
