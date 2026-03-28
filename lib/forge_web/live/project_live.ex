defmodule ForgeWeb.ProjectLive do
  use ForgeWeb, :live_view

  alias Forge.{Session, ProjectScanner}

  @impl true
  def mount(%{"path" => encoded_path}, _session, socket) do
    project_path = URI.decode(encoded_path)

    case ProjectScanner.scan(project_path) do
      {:ok, scan} ->
        config = scan.config
        sessions = sessions_for_project(project_path)
        pipeline_roles = load_pipeline_roles(config)

        socket =
          socket
          |> assign(:project_path, project_path)
          |> assign(:scan, scan)
          |> assign(:sessions, sessions)
          |> assign(:pipeline_roles, pipeline_roles)
          |> assign(:editing_roles, false)
          |> assign(:editing_settings, false)
          |> assign(:expanded_role, nil)
          |> assign(:new_role_name, "")
          |> assign(:new_role_type, "agent")
          # Settings form
          |> assign(:selected_skills, get_in(config, ["skills", "include"]) || [])
          |> assign(:test_command, get_in(config, ["commands", "test"]) || "")
          |> assign(:dev_start, get_in(config, ["commands", "dev_start"]) || "")
          |> assign(:branch_prefix, get_in(config, ["git", "branch_prefix"]) || "wt-")
          |> assign(:base_branch, get_in(config, ["git", "base_branch"]) || "main")
          |> assign(:saved, false)
          |> assign(:error, nil)

        {:ok, socket}

      {:error, reason} ->
        {:ok, socket |> assign(:error, reason) |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 text-base-content">
      <div class="border-t-[6px] border-base-content" />

      <%!-- Header --%>
      <div class="border-b border-base-content/10">
        <div class="max-w-3xl mx-auto px-8 py-4 flex items-baseline justify-between">
          <div class="flex items-baseline gap-4">
            <a
              href={~p"/"}
              class="font-display text-xl font-bold tracking-tight hover:opacity-60 transition-opacity"
            >
              Forge
            </a>
            <span class="text-base-content/20">/</span>
            <span class="font-mono text-sm">{@scan.name}</span>
          </div>
          <button
            id="project-theme-toggle"
            phx-hook="ThemeToggle"
            class="font-mono text-[10px] tracking-widest uppercase text-base-content/40 hover:text-base-content cursor-pointer"
          >
            Light / Dark
          </button>
        </div>
      </div>

      <div class="max-w-3xl mx-auto px-8 py-10">
        <%!-- Project header --%>
        <div class="mb-12">
          <h1 class="font-display text-5xl tracking-tighter leading-none mb-2">{@scan.name}</h1>
          <p class="font-mono text-xs text-base-content/40 break-all">{@project_path}</p>
          <div class="mt-4 border-t-4 border-base-content w-12" />
        </div>

        <%!-- Sessions --%>
        <section class="mb-16">
          <div class="flex items-baseline justify-between mb-6">
            <h2 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40">
              Sessions ({length(@sessions)})
            </h2>
            <a
              href={~p"/"}
              class="font-mono text-[10px] tracking-widest uppercase border border-base-content px-3 py-1 hover:bg-base-content hover:text-base-100 transition-colors duration-100"
            >
              New Session
            </a>
          </div>

          <div :if={@sessions == []} class="text-base-content/30 text-sm italic py-8">
            No active sessions
          </div>

          <div class="space-y-px">
            <a
              :for={s <- @sessions}
              href={~p"/session/#{s.id}"}
              class="flex items-center gap-4 px-5 py-4 border border-base-content/10 hover:border-base-content hover:bg-base-content hover:text-base-100 transition-colors duration-100 group"
            >
              <div class={[
                "w-2 h-2",
                session_status_style(s)
              ]} />
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium truncate">{s.goal || "---"}</div>
                <div class="font-mono text-[10px] text-base-content/40 group-hover:text-base-100/50 mt-0.5">
                  {s.id}
                </div>
              </div>
              <div class="text-right flex-shrink-0">
                <div class="font-mono text-xs">{s.done}/{s.total}</div>
                <div class="font-mono text-[10px] text-base-content/30 group-hover:text-base-100/40">
                  {session_status_label(s)}
                </div>
              </div>
            </a>
          </div>
        </section>

        <%!-- Roles (unified: pipeline + prompt overrides) --%>
        <section class="mb-16">
          <div class="border-t-2 border-base-content pt-8 mb-6">
            <div class="flex items-baseline justify-between">
              <h2 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40">
                Roles
              </h2>
              <button
                phx-click="toggle_roles_edit"
                class="font-mono text-[10px] tracking-widest uppercase text-base-content/40 hover:text-base-content cursor-pointer"
              >
                {if @editing_roles, do: "Done", else: "Edit"}
              </button>
            </div>
          </div>

          <p class="text-xs text-base-content/40 mb-6">
            Pipeline roles and their prompts. Override a role's instructions by editing its .forge/roles/ file.
          </p>

          <div class="space-y-px mb-6">
            <div :for={role <- @pipeline_roles} class="border border-base-content/10">
              <%!-- Role header row --%>
              <div class="flex items-center gap-4 px-5 py-3">
                <%!-- Editing: inline name/type fields --%>
                <form
                  :if={@editing_roles}
                  phx-submit="update_role"
                  class="flex items-center gap-3 flex-1"
                >
                  <input type="hidden" name="original_name" value={role.name} />
                  <input
                    type="text"
                    name="name"
                    value={role.name}
                    disabled={role.name in ["planner", "dev", "qa", "human"]}
                    class="font-mono text-[10px] tracking-[0.15em] uppercase border border-base-content/20 px-1.5 py-0.5 w-20 text-center bg-transparent focus:outline-none focus:border-base-content disabled:opacity-50"
                  />
                  <select
                    name="type"
                    class="font-mono text-[10px] bg-transparent border border-base-content/20 px-1 py-0.5"
                  >
                    <option value="agent" selected={role.type == "agent"}>agent</option>
                    <option value="human" selected={role.type == "human"}>human</option>
                    <option value="script" selected={role.type == "script"}>script</option>
                  </select>
                  <input
                    :if={role.type == "script"}
                    type="text"
                    name="script"
                    value={role.script || ""}
                    placeholder="path/to/script.sh"
                    class="flex-1 bg-transparent border-b border-base-content/20 py-1 font-mono text-xs focus:outline-none focus:border-base-content"
                  />
                  <span
                    :if={role.type != "script"}
                    class="flex-1 font-mono text-[10px] text-base-content/30"
                  >
                    {if override_exists?(@scan, role.name), do: "custom prompt", else: "built-in"}
                  </span>
                  <button
                    type="submit"
                    class="font-mono text-[9px] tracking-wider uppercase text-base-content/40 hover:text-base-content"
                  >
                    save
                  </button>
                  <button
                    :if={role.name not in ["planner", "dev", "qa", "human"]}
                    type="button"
                    phx-click="remove_role"
                    phx-value-name={role.name}
                    class="font-mono text-[9px] text-base-content/30 hover:text-base-content"
                  >
                    remove
                  </button>
                </form>

                <%!-- Read-only: clickable to expand --%>
                <button
                  :if={!@editing_roles}
                  phx-click="toggle_role_detail"
                  phx-value-role={role.name}
                  class="flex items-center gap-4 flex-1 text-left cursor-pointer group/row"
                >
                  <span class="font-mono text-[10px] tracking-[0.15em] uppercase border border-base-content/20 px-1.5 py-0.5 w-20 text-center">
                    @{role.name}
                  </span>
                  <span class="font-mono text-[10px] tracking-wider uppercase text-base-content/40 w-16">
                    {role.type}
                  </span>
                  <span class="text-xs text-base-content/40 flex-1 font-mono">
                    {role_status_label(@scan, role)}
                  </span>
                  <span class="font-mono text-[10px] text-base-content/30">
                    {if @expanded_role == role.name, do: "hide", else: "show"}
                  </span>
                </button>
              </div>

              <%!-- Expanded detail: built-in prompt + override editor --%>
              <div
                :if={@expanded_role == role.name && !@editing_roles}
                class="border-t border-base-content/10"
              >
                <%!-- Override (editable) --%>
                <div
                  :if={override = get_override(@scan, role.name)}
                  class="px-5 py-4 border-b border-base-content/10 bg-base-content/3"
                >
                  <div class="flex items-baseline justify-between mb-2">
                    <span class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40">
                      Project Override
                    </span>
                    <span class="font-mono text-[10px] text-base-content/30">
                      .forge/roles/{role.name}.md
                    </span>
                  </div>
                  <form phx-submit="save_override" class="space-y-2">
                    <input type="hidden" name="role" value={role.name} />
                    <textarea
                      name="content"
                      rows="10"
                      class="w-full bg-transparent border border-base-content/20 p-3 font-mono text-xs leading-relaxed focus:outline-none focus:border-base-content"
                    >{override}</textarea>
                    <button
                      type="submit"
                      class="font-mono text-[10px] tracking-widest uppercase border border-base-content px-3 py-1 hover:bg-base-content hover:text-base-100 transition-colors duration-100"
                    >
                      Save
                    </button>
                  </form>
                </div>

                <%!-- Built-in prompt (read-only) --%>
                <div
                  :if={
                    builtin = Forge.PromptBuilder.builtin_prompt(String.to_existing_atom(role.name))
                  }
                  class="px-5 py-4"
                >
                  <details class="group">
                    <summary class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 cursor-pointer mb-2">
                      Built-in prompt <span class="group-open:hidden">...</span>
                    </summary>
                    <pre class="font-mono text-xs text-base-content/50 whitespace-pre-wrap leading-relaxed max-h-64 overflow-y-auto">{builtin}</pre>
                  </details>
                </div>

                <%!-- Create override button --%>
                <div
                  :if={!override_exists?(@scan, role.name)}
                  class="px-5 py-3 border-t border-base-content/10"
                >
                  <button
                    phx-click="create_override"
                    phx-value-role={role.name}
                    class="font-mono text-[10px] tracking-widest uppercase text-base-content/40 hover:text-base-content"
                  >
                    + Create project override
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Add role (when editing) --%>
          <form
            :if={@editing_roles}
            phx-submit="add_role"
            class="border-2 border-dashed border-base-content/20 p-5 space-y-4"
          >
            <h3 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40">
              Add Role
            </h3>
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="font-mono text-[10px] text-base-content/50 block mb-1">Name</label>
                <input
                  type="text"
                  name="name"
                  value={@new_role_name}
                  placeholder="security"
                  class="w-full bg-transparent border-b border-base-content/30 py-1 font-mono text-sm focus:outline-none focus:border-base-content"
                />
              </div>
              <div>
                <label class="font-mono text-[10px] text-base-content/50 block mb-1">Type</label>
                <select
                  name="type"
                  class="w-full bg-transparent border-b border-base-content/30 py-1 font-mono text-sm focus:outline-none"
                >
                  <option value="agent" selected={@new_role_type == "agent"}>agent</option>
                  <option value="human" selected={@new_role_type == "human"}>human</option>
                  <option value="script" selected={@new_role_type == "script"}>script</option>
                </select>
              </div>
            </div>
            <button
              type="submit"
              class="border border-base-content px-5 py-1.5 font-mono text-[10px] tracking-widest uppercase hover:bg-base-content hover:text-base-100 transition-colors duration-100"
            >
              Add
            </button>
          </form>
        </section>

        <%!-- Settings --%>
        <section class="mb-16">
          <div class="border-t-2 border-base-content pt-8 mb-6">
            <div class="flex items-baseline justify-between">
              <h2 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40">
                Settings
              </h2>
              <button
                phx-click="toggle_settings_edit"
                class="font-mono text-[10px] tracking-widest uppercase text-base-content/40 hover:text-base-content cursor-pointer"
              >
                {if @editing_settings, do: "Close", else: "Edit"}
              </button>
            </div>
          </div>

          <%!-- Summary view --%>
          <div :if={!@editing_settings} class="grid grid-cols-2 gap-x-8 gap-y-4 text-xs">
            <div>
              <span class="font-mono text-[10px] text-base-content/40 uppercase">Test</span>
              <p class="font-mono mt-1">{@test_command || "---"}</p>
            </div>
            <div>
              <span class="font-mono text-[10px] text-base-content/40 uppercase">Dev start</span>
              <p class="font-mono mt-1">{@dev_start || "---"}</p>
            </div>
            <div>
              <span class="font-mono text-[10px] text-base-content/40 uppercase">Branch prefix</span>
              <p class="font-mono mt-1">{@branch_prefix}</p>
            </div>
            <div>
              <span class="font-mono text-[10px] text-base-content/40 uppercase">Base branch</span>
              <p class="font-mono mt-1">{@base_branch}</p>
            </div>
            <div class="col-span-2">
              <span class="font-mono text-[10px] text-base-content/40 uppercase">Skills</span>
              <p class="font-mono mt-1">
                {if @selected_skills == [], do: "---", else: Enum.join(@selected_skills, ", ")}
              </p>
            </div>
          </div>

          <%!-- Edit form --%>
          <form :if={@editing_settings} phx-submit="save_settings" class="space-y-6">
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="font-mono text-[10px] text-base-content/50 block mb-1">
                  Test command
                </label>
                <input
                  type="text"
                  name="test_command"
                  value={@test_command}
                  class="w-full bg-transparent border-b border-base-content/30 py-2 font-mono text-sm focus:outline-none focus:border-base-content"
                />
              </div>
              <div>
                <label class="font-mono text-[10px] text-base-content/50 block mb-1">Dev start</label>
                <input
                  type="text"
                  name="dev_start"
                  value={@dev_start}
                  class="w-full bg-transparent border-b border-base-content/30 py-2 font-mono text-sm focus:outline-none focus:border-base-content"
                />
              </div>
            </div>
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
            <div>
              <label class="font-mono text-[10px] text-base-content/50 block mb-2">Skills</label>
              <div class="grid grid-cols-3 gap-x-4 gap-y-1">
                <label
                  :for={skill <- @scan.skills}
                  class="flex items-center gap-2 py-1 cursor-pointer text-base-content/60 hover:text-base-content"
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
            <button
              type="submit"
              class={[
                "border-2 border-base-content px-8 py-2.5 font-mono text-[11px] tracking-widest uppercase transition-colors duration-100",
                "hover:bg-base-content hover:text-base-100",
                @saved && "bg-base-content text-base-100"
              ]}
            >
              {if @saved, do: "Saved", else: "Save"}
            </button>
          </form>
        </section>
      </div>
    </div>
    """
  end

  # -- Events -------------------------------------------------------

  @impl true
  def handle_event("toggle_roles_edit", _params, socket) do
    {:noreply, assign(socket, editing_roles: !socket.assigns.editing_roles, expanded_role: nil)}
  end

  def handle_event("toggle_settings_edit", _params, socket) do
    {:noreply, assign(socket, :editing_settings, !socket.assigns.editing_settings)}
  end

  def handle_event("toggle_role_detail", %{"role" => role}, socket) do
    expanded = if socket.assigns.expanded_role == role, do: nil, else: role
    {:noreply, assign(socket, :expanded_role, expanded)}
  end

  def handle_event("add_role", %{"name" => name, "type" => type}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, socket}
    else
      role = %{name: name, type: type, script: nil}
      roles = socket.assigns.pipeline_roles ++ [role]
      save_pipeline_roles(socket.assigns.project_path, roles, socket.assigns)
      {:noreply, assign(socket, pipeline_roles: roles, new_role_name: "")}
    end
  end

  def handle_event("update_role", params, socket) do
    original = params["original_name"]
    name = String.trim(params["name"] || original)
    type = params["type"]
    script = if(params["script"] in [nil, ""], do: nil, else: params["script"])

    roles =
      Enum.map(socket.assigns.pipeline_roles, fn role ->
        if role.name == original do
          %{role | name: name, type: type, script: script}
        else
          role
        end
      end)

    save_pipeline_roles(socket.assigns.project_path, roles, socket.assigns)
    {:noreply, assign(socket, :pipeline_roles, roles)}
  end

  def handle_event("remove_role", %{"name" => name}, socket) do
    roles = Enum.reject(socket.assigns.pipeline_roles, &(&1.name == name))
    save_pipeline_roles(socket.assigns.project_path, roles, socket.assigns)
    {:noreply, assign(socket, :pipeline_roles, roles)}
  end

  def handle_event("create_override", %{"role" => role}, socket) do
    roles_dir = Path.join(socket.assigns.project_path, ".forge/roles")
    File.mkdir_p!(roles_dir)

    content = """
    # Project override for @#{role}
    # This is appended to Forge's built-in #{role} prompt.
    # Add project-specific instructions below.

    """

    File.write!(Path.join(roles_dir, "#{role}.md"), content)
    {:ok, scan} = ProjectScanner.scan(socket.assigns.project_path)
    {:noreply, assign(socket, :scan, scan)}
  end

  def handle_event("save_override", %{"role" => role, "content" => content}, socket) do
    path = Path.join([socket.assigns.project_path, ".forge", "roles", "#{role}.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    {:ok, scan} = ProjectScanner.scan(socket.assigns.project_path)
    {:noreply, assign(socket, :scan, scan)}
  end

  def handle_event("save_settings", params, socket) do
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
      }
    }

    config = merge_pipeline_into_config(config, socket.assigns.pipeline_roles)
    ProjectScanner.save_config(socket.assigns.project_path, config)

    {:noreply,
     socket
     |> assign(:saved, true)
     |> assign(:selected_skills, skills)
     |> assign(:test_command, params["test_command"] || "")
     |> assign(:dev_start, params["dev_start"] || "")
     |> assign(:branch_prefix, params["branch_prefix"] || "wt-")
     |> assign(:base_branch, params["base_branch"] || "main")}
  end

  # -- Private ------------------------------------------------------

  defp sessions_for_project(project_path) do
    Session.list_sessions()
    |> Enum.filter(fn s ->
      s.repo_path && String.starts_with?(s.repo_path, project_path)
    end)
  end

  defp load_pipeline_roles(config) do
    defaults = [
      %{name: "planner", type: "agent", script: nil},
      %{name: "dev", type: "agent", script: nil},
      %{name: "qa", type: "agent", script: nil},
      %{name: "human", type: "human", script: nil}
    ]

    custom =
      (config["pipeline_roles"] || [])
      |> Enum.map(fn r ->
        %{
          name: r["name"],
          type: r["type"] || "agent",
          script: r["script"]
        }
      end)

    defaults ++ custom
  end

  defp save_pipeline_roles(project_path, roles, assigns) do
    config = %{
      "project" => %{"name" => assigns.scan.name},
      "skills" => %{"include" => assigns.selected_skills},
      "commands" =>
        %{"test" => assigns.test_command, "dev_start" => assigns.dev_start}
        |> Enum.reject(fn {_k, v} -> v == "" end)
        |> Map.new(),
      "git" => %{
        "branch_prefix" => assigns.branch_prefix,
        "base_branch" => assigns.base_branch
      }
    }

    config = merge_pipeline_into_config(config, roles)
    ProjectScanner.save_config(project_path, config)
  end

  defp merge_pipeline_into_config(config, roles) do
    custom =
      roles
      |> Enum.reject(&(&1.name in ["planner", "dev", "qa", "human"]))
      |> Enum.map(fn r ->
        %{"name" => r.name, "type" => r.type, "script" => r.script}
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      end)

    if custom == [] do
      config
    else
      Map.put(config, "pipeline_roles_json", Jason.encode!(custom))
    end
  end

  defp override_exists?(scan, role_name) do
    role_str = to_string(role_name)
    Path.join(scan.path, ".forge/roles/#{role_str}.md") |> File.exists?()
  end

  defp get_override(scan, role_name) do
    path = Path.join(scan.path, ".forge/roles/#{to_string(role_name)}.md")
    if File.exists?(path), do: File.read!(path)
  end

  defp role_status_label(scan, role) do
    cond do
      role.type == "script" -> role.script || "---"
      role.type == "human" -> "---"
      override_exists?(scan, role.name) -> "custom prompt"
      true -> "built-in"
    end
  end

  defp session_status_style(session) do
    cond do
      session.done == session.total and session.total > 0 -> "bg-base-content"
      session.done > 0 -> "bg-base-content/50 animate-pulse"
      true -> "border border-base-content/30"
    end
  end

  defp session_status_label(session) do
    cond do
      session.done == session.total and session.total > 0 -> "complete"
      session.done > 0 -> "working"
      true -> "pending"
    end
  end
end
