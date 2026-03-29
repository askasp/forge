defmodule ForgeWeb.DashboardLive do
  use ForgeWeb, :live_view

  alias Forge.TaskEngine

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session =
      Forge.Repo.get(Forge.Schemas.Session, session_id)
      |> case do
        nil -> nil
        s -> Forge.Repo.preload(s, :project)
      end

    if session do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Forge.PubSub, "session:#{session_id}")
        :timer.send_interval(1_000, self(), :tick)
      end

      tasks = TaskEngine.list_tasks(session_id)
      {done, total} = TaskEngine.progress(session_id)
      steps = Enum.map(tasks, &task_to_step/1)
      orch_state = derive_orchestrator_state(tasks, session)
      all_sessions = Forge.Session.list_sessions()
      projects = group_sessions(all_sessions)

      socket =
        socket
        |> assign(:session_id, session_id)
        |> assign(:goal, session.goal)
        |> assign(:steps, steps)
        |> assign(:done, done)
        |> assign(:total, total)
        |> assign(:agent_role, current_agent_role(tasks))
        |> assign(:agent_output, [])
        |> assign(:agent_started_at, nil)
        |> assign(:running_task_id, nil)
        |> assign(:orchestrator_state, orch_state)
        |> assign(:step_diffs, %{})
        |> assign(:step_outputs, %{})
        |> assign(:project_name, (session.project && session.project.name) || "—")
        |> assign(:automation, session.automation)
        |> assign(:projects, projects)
        |> assign(:editing_step, nil)
        |> assign(:page_title, page_title(orch_state, current_agent_role(tasks), done, total))
        |> assign(:ask_open, false)
        |> assign(:ask_messages, [])
        |> assign(:ask_port, nil)
        |> assign(:ask_streaming, false)
        |> assign(:ask_workdir, session.worktree_path)
        |> assign(:project_path, session.project && session.project.repo_path)
        |> assign(:plan_markdown, session.plan_markdown)
        |> assign(:plan_html, Forge.PlanRenderer.render(session.plan_markdown))
        |> assign(:sidebar_open, true)
        |> assign(:show_shortcuts, false)
        |> assign(:merge_error, nil)
        |> assign(:user_notes, %{})
        |> assign(:planner_notes, [])
        |> assign(:tick_count, 0)

      {:ok, socket}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="flex flex-col h-screen bg-base-100 text-base-content"
      id="dashboard"
      phx-hook="KeyboardShortcuts"
    >
      <div id="notifier" phx-hook="Notifications" class="hidden" />
      <%!-- Header --%>
      <header class="border-b-2 border-base-content">
        <div class="flex items-baseline justify-between px-6 py-3">
          <div class="flex items-baseline gap-3">
            <a
              href={~p"/"}
              class="font-display text-xl font-bold tracking-tight hover:opacity-60 transition-opacity"
            >
              Forge
            </a>
            <span class="text-base-content/20">/</span>
            <span class="text-sm tracking-wide uppercase">{@project_name}</span>
          </div>
          <div class="flex items-center gap-5">
            <button
              phx-click="cycle_automation"
              class={[
                "font-mono text-[10px] tracking-widest uppercase px-2 py-0.5 cursor-pointer transition-colors duration-100",
                @automation == :autopilot && "bg-base-content text-base-100",
                @automation == :supervised &&
                  "border border-base-content/40 text-base-content/60 hover:border-base-content",
                @automation == :manual &&
                  "border border-dashed border-base-content/30 text-base-content/40 hover:border-base-content"
              ]}
            >
              {@automation}
            </button>
            <span class="font-mono text-xs">{@done}/{@total}</span>
            <span class={[
              "font-mono text-[10px] tracking-widest uppercase border border-base-content px-2 py-0.5",
              @orchestrator_state in [:cruising, :planning] && "relative overflow-hidden"
            ]}>
              <span
                :if={@orchestrator_state in [:cruising, :planning]}
                class="absolute inset-0 overflow-hidden"
              >
                <span class="block h-full w-1/3 bg-base-content/10 animate-sweep" />
              </span>
              <span class="relative">{orchestrator_label(@orchestrator_state)}</span>
            </span>
            <button
              id="dash-theme"
              phx-hook="ThemeToggle"
              class="font-mono text-[10px] tracking-widest uppercase text-base-content/40 hover:text-base-content cursor-pointer"
            >
              Light / Dark
            </button>
          </div>
        </div>
      </header>

      <div class="flex-1 flex overflow-hidden">
        <%!-- Sidebar: sessions by project --%>
        <aside class="w-56 flex-shrink-0 border-r border-base-content/10 overflow-y-auto">
          <div class="p-3">
            <div :for={{project, sessions} <- @projects} class="mb-4">
              <h3 class="font-mono text-[9px] tracking-[0.2em] uppercase text-base-content/30 mb-1 px-2">
                {project}
              </h3>
              <div
                :for={s <- sessions}
                class="flex items-center group"
              >
                <a
                  href={~p"/session/#{s.id}"}
                  class={[
                    "flex items-center gap-2 px-2 py-1.5 text-xs transition-colors duration-100 flex-1 min-w-0",
                    s.id == @session_id && "bg-base-content text-base-100",
                    s.id != @session_id && "hover:bg-base-content/5"
                  ]}
                >
                  <.session_indicator s={s} />
                  <span class="truncate">{s.goal || s.id}</span>
                  <span
                    :if={s.waiting_human > 0 && s.id != @session_id}
                    class="font-mono text-[8px] tracking-wider uppercase text-base-content/50 flex-shrink-0"
                  >
                    input
                  </span>
                  <span
                    :if={s.done == s.total && s.total > 0 && s.id != @session_id}
                    class="font-mono text-[8px] tracking-wider uppercase text-base-content/50 flex-shrink-0"
                  >
                    merge
                  </span>
                </a>
                <button
                  :if={s.id != @session_id}
                  phx-click="delete_session"
                  phx-value-id={s.id}
                  data-confirm="Delete this session and its worktree?"
                  class="px-1 py-1 text-base-content/0 group-hover:text-base-content/20 hover:!text-error transition-colors shrink-0"
                  title="Delete session"
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="w-3 h-3"
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
            <a
              href={~p"/"}
              class="flex items-center gap-2 px-2 py-1.5 text-xs text-base-content/30 hover:text-base-content"
            >
              + New session
            </a>
          </div>
        </aside>

        <%!-- Main timeline --%>
        <main class="flex-1 overflow-y-auto" id="timeline" phx-hook="AutoScroll">
          <div class="max-w-3xl mx-auto py-8 px-8">
            <%!-- Goal --%>
            <div :if={@goal} class="mb-10">
              <h2 class="font-display text-3xl tracking-tight leading-tight mb-2">
                {strip_markdown(@goal)}
              </h2>
              <div class="mt-4 border-t-4 border-base-content w-12" />
            </div>

            <%!-- Merged banner --%>
            <div
              :if={@orchestrator_state == :merged}
              class="mb-6 border-2 border-base-content p-6 bg-base-200"
            >
              <div class="flex items-center gap-3 mb-2">
                <span class="font-mono text-[10px] tracking-[0.15em] uppercase border border-base-content px-2 py-0.5">
                  Merged
                </span>
                <span class="text-sm">Branch merged into main</span>
              </div>
              <p class="text-xs text-base-content/50">
                Worktree removed and branch cleaned up.
              </p>
            </div>

            <%!-- Merge error --%>
            <div
              :if={assigns[:merge_error]}
              class="mb-6 border-2 border-base-content/40 p-6 bg-base-200/50"
            >
              <div class="flex items-center gap-3 mb-2">
                <span class="font-mono text-[10px] tracking-[0.15em] uppercase border-2 border-base-content px-2 py-0.5 font-bold">
                  Error
                </span>
                <span class="text-sm">Merge failed</span>
              </div>
              <p class="font-mono text-xs text-base-content/60">{@merge_error}</p>
            </div>

            <%!-- Planning card --%>
            <div
              :if={
                @orchestrator_state in [:planning, :planning_done] ||
                  (@steps == [] && @agent_output != []) ||
                  @plan_html
              }
              class="mb-6"
            >
              <article class={[
                "border-2 transition-colors duration-100 relative overflow-hidden",
                @orchestrator_state == :planning && "border-base-content bg-base-200",
                @orchestrator_state != :planning && "border-base-content/15"
              ]}>
                <%!-- Sweep bar when planning --%>
                <div
                  :if={@orchestrator_state == :planning}
                  class="absolute top-0 left-0 right-0 h-[2px] overflow-hidden"
                >
                  <div class="h-full w-1/4 bg-base-content/60 animate-sweep" />
                </div>
                <div class={[
                  "flex items-center gap-3 px-4 py-2.5 border-b",
                  @orchestrator_state == :planning && "border-base-content/15",
                  @orchestrator_state != :planning && "border-base-content/10"
                ]}>
                  <span class="font-mono text-[10px] tracking-[0.15em] uppercase border border-base-content/30 px-1.5 py-0.5 text-base-content/50">
                    @planner
                  </span>
                  <span class="text-sm">
                    {if @orchestrator_state == :planning, do: "Planning...", else: "Plan"}
                  </span>
                  <span
                    :if={@orchestrator_state == :planning && @agent_output != []}
                    class="font-mono text-[10px] text-base-content/30"
                  >
                    {length(@agent_output)} events
                  </span>
                  <div :if={@orchestrator_state == :planning} class="ml-auto flex items-center gap-2">
                    <button
                      phx-click="kill_task"
                      phx-value-id={@running_task_id}
                      data-confirm="Kill the planner?"
                      class="font-mono text-[9px] text-base-content/30 hover:text-base-content transition-colors"
                      title="Kill planner"
                    >
                      &#x25A0;
                    </button>
                    <button
                      phx-click="restart_task"
                      phx-value-id={@running_task_id}
                      data-confirm="Restart the planner?"
                      class="font-mono text-[9px] text-base-content/30 hover:text-base-content transition-colors"
                      title="Restart planner"
                    >
                      &#x21bb;
                    </button>
                  </div>
                </div>
                <div class="px-4 py-3">
                  <%!-- Live agent output while planning --%>
                  <div
                    :if={@agent_output != [] && @orchestrator_state == :planning}
                    class="font-mono text-xs leading-relaxed max-h-64 overflow-y-auto p-3 bg-base-200/60"
                    id="planner-output"
                    phx-hook="AutoScroll"
                  >
                    <div
                      :for={line <- @agent_output}
                      class={output_line_class(line)}
                    >
                      {line}
                    </div>
                  </div>
                  <div
                    :if={@orchestrator_state == :planning && @agent_output == []}
                    class="font-mono text-xs italic text-base-content/30"
                  >
                    Starting...
                  </div>

                  <%!-- User notes sent to planner --%>
                  <div :if={@orchestrator_state == :planning && @planner_notes != []} class="space-y-1 pt-2">
                    <div
                      :for={note <- @planner_notes}
                      class="font-mono text-xs text-base-content/50 pl-3 border-l-2 border-base-content/15"
                    >
                      <span class="text-base-content/30">you:</span> {note}
                    </div>
                  </div>

                  <%!-- Chat input while planner is running --%>
                  <form :if={@orchestrator_state == :planning} phx-submit="send_note" class="flex gap-2 pt-2">
                    <input type="hidden" name="task_id" value={@running_task_id} />
                    <input
                      type="text"
                      name="message"
                      placeholder="Add context..."
                      class="flex-1 bg-transparent border border-base-content/15 px-2 py-1 font-mono text-xs focus:outline-none focus:border-base-content/40 placeholder:text-base-content/20"
                      autocomplete="off"
                    />
                    <button
                      type="submit"
                      class="font-mono text-[9px] tracking-wider uppercase border border-base-content/20 px-2 py-1 hover:bg-base-content hover:text-base-100 transition-colors"
                    >
                      Send
                    </button>
                  </form>

                  <%!-- Plan narrative --%>
                  <div :if={@orchestrator_state != :planning && @plan_html} class="space-y-4">
                    <details open={@orchestrator_state == :planning_done} class="group">
                      <summary class="cursor-pointer font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 hover:text-base-content">
                        {if @orchestrator_state == :planning_done, do: "Plan", else: "View plan"}
                      </summary>
                      <div
                        class="mt-2 plan-content max-h-[32rem] overflow-y-auto"
                        id="plan-narrative"
                        phx-hook="MermaidRenderer"
                      >
                        {Phoenix.HTML.raw(@plan_html)}
                      </div>
                    </details>

                    <%!-- Edit controls only during planning_done --%>
                    <div :if={@orchestrator_state == :planning_done} class="border-t border-base-content/10 pt-3 space-y-3">
                      <div class="text-xs text-base-content/50">
                        {length(Enum.filter(@steps, &(&1.role != :planner)))} steps created. Edit below or refine the plan.
                      </div>

                      <%!-- Planner chat input --%>
                      <form phx-submit="planner_chat" class="flex gap-2">
                        <input
                          type="text"
                          name="message"
                          placeholder="Change the plan..."
                          autocomplete="off"
                          class="flex-1 bg-transparent border-b border-base-content/20 px-0 py-2 text-sm focus:outline-none focus:border-base-content placeholder:text-base-content/20 placeholder:italic"
                        />
                        <button
                          type="submit"
                          class="font-mono text-[10px] tracking-widest uppercase border border-base-content/30 px-3 py-1.5 hover:bg-base-content hover:text-base-100 hover:border-base-content transition-colors duration-100"
                        >
                          Re-plan
                        </button>
                      </form>

                      <div class="flex gap-2 pt-1">
                        <button
                          phx-click="continue"
                          class="font-mono text-[10px] tracking-widest uppercase bg-base-content text-base-100 px-4 py-1.5 border border-base-content hover:bg-transparent hover:text-base-content transition-colors duration-100"
                        >
                          Start
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              </article>
            </div>

            <%!-- Empty state --%>
            <div
              :if={@steps == [] && @agent_output == [] && @orchestrator_state == :idle}
              class="py-24 text-center"
            >
              <p class="font-display text-2xl italic text-base-content/15">Waiting for planner</p>
            </div>

            <%!-- Step cards — stacked timeline (exclude planner, it has its own card above) --%>
            <div class="space-y-3">
              <div
                :for={step <- Enum.filter(@steps, &(&1.role != :planner))}
                id={"step-#{step.index}"}
                class="scroll-mt-4"
              >
                <.step_card
                  step={step}
                  is_running={is_running?(step, assigns)}
                  agent_output={if(is_running?(step, assigns), do: @agent_output, else: [])}
                  saved_output={@step_outputs[step.index]}
                  diff={@step_diffs[step.index]}
                  editing={@editing_step == step.index}
                  user_notes={Map.get(@user_notes, step.id, [])}
                />
              </div>
            </div>

            <%!-- Add task --%>
            <div :if={@steps != [] && @orchestrator_state not in [:planning, :idle]} class="mt-4">
              <form phx-submit="add_task" class="flex gap-2">
                <input
                  type="text"
                  name="title"
                  placeholder="Add a task..."
                  autocomplete="off"
                  class="flex-1 bg-transparent border-b border-base-content/20 px-0 py-2 text-sm focus:outline-none focus:border-base-content placeholder:text-base-content/20 placeholder:italic"
                />
                <button
                  type="submit"
                  class="font-mono text-[10px] tracking-widest uppercase border border-base-content/30 px-3 py-1.5 hover:bg-base-content hover:text-base-100 hover:border-base-content transition-colors duration-100"
                >
                  Add
                </button>
              </form>
            </div>

            <%!-- Error card --%>
            <div
              :for={step <- Enum.filter(@steps, &(&1.status == :failed))}
              class="mt-6 border-2 border-base-content p-5"
            >
              <div class="flex items-center gap-3 mb-3">
                <span class="font-mono text-[10px] tracking-widest uppercase border-2 border-base-content px-2 py-0.5 font-bold">
                  Error
                </span>
                <span class="font-mono text-xs text-base-content/60">
                  @{step.role} failed — {step.description}
                </span>
              </div>
              <div
                :if={step.details != []}
                class="font-mono text-xs leading-relaxed max-h-48 overflow-y-auto p-3 bg-base-200 mb-4"
              >
                <div
                  :for={line <- step.details}
                  class="whitespace-pre-wrap break-all text-base-content/70"
                >
                  {line}
                </div>
              </div>
              <div class="flex gap-2">
                <button
                  phx-click="retry"
                  class="bg-base-content text-base-100 px-5 py-1.5 font-mono text-[10px] tracking-widest uppercase border border-base-content hover:bg-transparent hover:text-base-content transition-colors duration-100"
                >
                  Retry
                </button>
                <button
                  phx-click="skip"
                  class="px-5 py-1.5 font-mono text-[10px] tracking-widest uppercase border border-base-content hover:bg-base-content hover:text-base-100 transition-colors duration-100"
                >
                  Skip
                </button>
              </div>
            </div>
          </div>
        </main>

        <%!-- Q&A side panel --%>
        <aside
          :if={@ask_open}
          class="w-96 flex-shrink-0 border-l border-base-content/10 flex flex-col bg-base-200/40"
        >
          <div class="flex items-center justify-between px-4 py-2.5 border-b border-base-content/10">
            <span class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40">
              Ask
            </span>
            <button
              phx-click="toggle_ask"
              class="font-mono text-[10px] text-base-content/30 hover:text-base-content cursor-pointer"
            >
              Cmd+K
            </button>
          </div>

          <div class="flex-1 overflow-y-auto p-4 space-y-4" id="ask-messages" phx-hook="AutoScroll">
            <div :if={@ask_messages == []} class="text-center py-12">
              <p class="font-mono text-xs text-base-content/20 italic">
                Ask anything about the codebase
              </p>
            </div>
            <div :for={msg <- @ask_messages} class="space-y-1">
              <div :if={msg.role == :user} class="flex gap-3">
                <span class="font-mono text-[10px] tracking-wider uppercase text-base-content/50 mt-0.5 w-10 text-right flex-shrink-0">
                  you
                </span>
                <p class="text-sm">{msg.content}</p>
              </div>
              <div :if={msg.role == :assistant} class="flex gap-3">
                <span class="font-mono text-[10px] tracking-wider uppercase text-base-content/25 mt-0.5 w-10 text-right flex-shrink-0">
                  ai
                </span>
                <div class="text-sm text-base-content/70 whitespace-pre-wrap break-words font-mono text-xs leading-relaxed">
                  {msg.content}
                </div>
              </div>
            </div>
            <div :if={@ask_streaming} class="flex gap-3">
              <span class="font-mono text-[10px] tracking-wider uppercase text-base-content/25 mt-0.5 w-10 text-right flex-shrink-0">
                ai
              </span>
              <span class="font-mono text-xs text-base-content/30 animate-pulse">thinking...</span>
            </div>
          </div>

          <div class="border-t border-base-content/10 p-3">
            <form phx-submit="ask_question" class="flex gap-2">
              <input
                type="text"
                name="question"
                placeholder="What does this module do?"
                autocomplete="off"
                disabled={@ask_streaming}
                class="flex-1 bg-transparent border-b border-base-content/20 px-0 py-2 text-sm focus:outline-none focus:border-base-content placeholder:text-base-content/20 placeholder:italic disabled:opacity-40"
              />
              <button
                type="submit"
                disabled={@ask_streaming}
                class="font-mono text-[10px] tracking-widest uppercase border border-base-content px-3 py-1.5 hover:bg-base-content hover:text-base-100 transition-colors duration-100 disabled:opacity-30"
              >
                Ask
              </button>
            </form>
          </div>
        </aside>
      </div>

      <%!-- Shortcuts overlay --%>
      <div
        :if={@show_shortcuts}
        class="fixed inset-0 bg-base-100/80 z-50 flex items-center justify-center"
        phx-click="toggle_shortcuts"
      >
        <div
          class="border-2 border-base-content bg-base-100 p-8 max-w-sm"
          phx-click-away="toggle_shortcuts"
        >
          <h3 class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 mb-4">
            Keyboard Shortcuts
          </h3>
          <div class="space-y-2 font-mono text-xs">
            <div class="flex justify-between">
              <span class="text-base-content/60">Continue</span><span class="text-base-content/30">Cmd+Enter</span>
            </div>
            <div class="flex justify-between">
              <span class="text-base-content/60">Pause</span><span class="text-base-content/30">Esc</span>
            </div>
            <div class="flex justify-between">
              <span class="text-base-content/60">Skip</span><span class="text-base-content/30">Cmd+.</span>
            </div>
            <div class="flex justify-between">
              <span class="text-base-content/60">Ask panel</span><span class="text-base-content/30">Cmd+K</span>
            </div>
            <div class="flex justify-between">
              <span class="text-base-content/60">Sessions</span><span class="text-base-content/30">Cmd+B</span>
            </div>
            <div class="flex justify-between">
              <span class="text-base-content/60">New session</span><span class="text-base-content/30">Alt+N</span>
            </div>
            <div class="flex justify-between">
              <span class="text-base-content/60">Kill session</span><span class="text-base-content/30">Cmd+Del</span>
            </div>
            <div class="flex justify-between">
              <span class="text-base-content/60">Shortcuts</span><span class="text-base-content/30">?</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- Footer --%>
      <footer class="border-t-2 border-base-content">
        <div class="flex items-center justify-between px-6 py-2.5">
          <.footer_buttons
            state={@orchestrator_state}
            agent_role={@agent_role}
            agent_started_at={@agent_started_at}
            merge_error={@merge_error}
            done={@done}
            total={@total}
          />
          <div class="flex items-center gap-3 font-mono text-[10px] text-base-content/35">
            <button
              phx-click="kill_session"
              data-confirm="Kill this session and delete its worktree?"
              class="hover:text-base-content cursor-pointer"
            >
              Kill
            </button>
            <span class="text-base-content/15">|</span>
            <button phx-click="toggle_sidebar" class="hover:text-base-content/50 cursor-pointer">
              Cmd+B
            </button>
            <button phx-click="new_session" class="hover:text-base-content/50 cursor-pointer">
              Alt+N
            </button>
            <button phx-click="toggle_ask" class="hover:text-base-content/50 cursor-pointer">
              Cmd+K
            </button>
            <button phx-click="toggle_shortcuts" class="hover:text-base-content/50 cursor-pointer">
              ?
            </button>
          </div>
        </div>
      </footer>
    </div>
    """
  end

  # ── Step Card ────────────────────────────────────────────────────

  defp step_card(assigns) do
    ~H"""
    <article class={[
      "border transition-colors duration-100 relative overflow-hidden",
      @step.status == :done && "border-base-content/15",
      @step.status == :failed && "border-2 border-base-content/40 bg-base-200/50",
      @is_running && "border-2 border-base-content bg-base-200",
      @step.status == :todo && !@is_running && "border-base-content/10 hover:border-base-content/30"
    ]}>
      <%!-- Sweep bar: thin animated line across top when running --%>
      <div :if={@is_running} class="absolute top-0 left-0 right-0 h-[2px] overflow-hidden">
        <div class="h-full w-1/4 bg-base-content/60 animate-sweep" />
      </div>
      <%!-- Header: index + role + description (editable) + tags --%>
      <div class={[
        "flex items-start gap-3 px-4",
        @step.status == :done && "py-2",
        @step.status != :done && "py-3",
        (@step.status == :done || @is_running || @step.status == :failed || @diff) && "border-b",
        @is_running && "border-base-content/15",
        !@is_running && "border-base-content/5"
      ]}>
        <span class={[
          "font-mono text-[10px] mt-1 w-4 text-right flex-shrink-0",
          @step.status == :done && "text-base-content/30",
          @step.status == :failed && "text-base-content/60",
          @is_running && "text-base-content/50",
          @step.status == :todo && !@is_running && "text-base-content/30"
        ]}>
          {if @step.status == :done, do: raw("&#x2713;"), else: @step.index}
        </span>

        <span class={[
          "font-mono text-[10px] tracking-[0.15em] uppercase border px-1.5 py-0.5 mt-0.5 flex-shrink-0",
          @step.status == :done && "border-base-content/20 text-base-content/40",
          @is_running && "border-base-content/40 text-base-content/80",
          @step.status == :todo && !@is_running && "border-base-content/20 text-base-content/50"
        ]}>
          @{@step.role}
        </span>

        <%!-- Description: editable on click (only for non-done tasks) --%>
        <div class="flex-1 min-w-0">
          <form :if={@editing && @step.status != :done} phx-submit="save_step" class="space-y-2">
            <input type="hidden" name="index" value={@step.index} />
            <div class="flex gap-2">
              <textarea
                name="description"
                rows="2"
                class="flex-1 bg-transparent border border-base-content/30 p-2 text-sm focus:outline-none focus:border-base-content font-mono"
                phx-mounted={JS.dispatch("focus")}
              >{@step.description}</textarea>
              <div class="flex flex-col gap-1">
                <button
                  type="submit"
                  class="font-mono text-[9px] tracking-wider uppercase border border-base-content px-2 py-1 hover:bg-base-content hover:text-base-100"
                >
                  Save
                </button>
                <button
                  type="button"
                  phx-click="cancel_edit"
                  class="font-mono text-[9px] tracking-wider uppercase text-base-content/40"
                >
                  Cancel
                </button>
              </div>
            </div>
            <div>
              <label class="font-mono text-[9px] tracking-[0.2em] uppercase text-base-content/30">
                Acceptance criteria
              </label>
              <textarea
                name="acceptance_criteria"
                rows="3"
                class="w-full bg-transparent border border-base-content/20 p-2 text-xs focus:outline-none focus:border-base-content font-mono mt-1"
                placeholder="- Endpoint returns 200&#10;- Tests pass"
              >{@step.acceptance_criteria}</textarea>
            </div>
          </form>
          <%!-- Done: static text, no click --%>
          <div
            :if={!@editing && @step.status == :done}
            class="text-sm text-base-content/50 line-through decoration-base-content/15"
          >
            {highlight_files(@step.description)}
          </div>
          <%!-- Not done: clickable to edit --%>
          <div
            :if={!@editing && @step.status != :done}
            class="text-sm cursor-pointer"
            phx-click="edit_step"
            phx-value-index={@step.index}
          >
            {highlight_files(@step.description)}
          </div>
        </div>

        <div class="flex items-center gap-2 flex-shrink-0 mt-0.5">
          <span :if={@step.tags[:pr]} class="font-mono text-[10px] text-base-content/25">
            PR {@step.tags[:pr]}
          </span>
          <button
            :if={@is_running}
            phx-click="kill_task"
            phx-value-id={@step.id}
            data-confirm="Kill this task?"
            class="font-mono text-[9px] text-base-content/30 hover:text-base-content transition-colors"
            title="Kill task"
          >
            &#x25A0;
          </button>
          <button
            :if={@is_running}
            phx-click="restart_task"
            phx-value-id={@step.id}
            data-confirm="Kill and restart this task?"
            class="font-mono text-[9px] text-base-content/30 hover:text-base-content transition-colors"
            title="Kill & restart"
          >
            &#x21bb;
          </button>
          <button
            :if={@step.status == :failed}
            phx-click="retry_task"
            phx-value-id={@step.id}
            class="font-mono text-[9px] text-base-content/30 hover:text-base-content transition-colors"
            title="Retry task"
          >
            &#x21bb;
          </button>
          <button
            :if={@step.status == :todo && !@is_running && !@editing}
            phx-click="delete_step"
            phx-value-index={@step.index}
            class="font-mono text-[9px] text-base-content/20 hover:text-base-content transition-colors"
          >
            &#x2715;
          </button>
        </div>
      </div>

      <%!-- Acceptance criteria --%>
      <div
        :if={@step.acceptance_criteria && @step.acceptance_criteria != ""}
        class="px-4 py-2 border-b border-base-content/5"
      >
        <details class="group">
          <summary class="cursor-pointer font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/30 hover:text-base-content">
            Acceptance criteria
          </summary>
          <div class="mt-2 text-xs text-base-content/60 whitespace-pre-wrap pl-2 border-l-2 border-base-content/10">
            {@step.acceptance_criteria}
          </div>
        </details>
      </div>

      <%!-- Human Q&A --%>
      <div
        :if={@step.role == :human && @step.state in [:planned, :assigned]}
        class="px-4 py-4 space-y-4 bg-base-200/30"
      >
        <div
          :if={@step.prompt && @step.prompt != ""}
          class="text-sm whitespace-pre-wrap leading-relaxed"
        >
          {@step.prompt}
        </div>
        <form phx-submit="submit_human" class="space-y-3">
          <input type="hidden" name="task_id" value={@step.id} />
          <textarea
            name="response"
            rows="3"
            placeholder="Your answer..."
            class="w-full bg-transparent border-2 border-base-content/30 p-3 text-sm focus:outline-none focus:border-base-content placeholder:text-base-content/20 resize-y"
          />
          <button
            type="submit"
            class="bg-base-content text-base-100 px-5 py-1.5 font-mono text-[10px] tracking-widest uppercase border border-base-content hover:bg-transparent hover:text-base-content transition-colors duration-100"
          >
            Submit &amp; Continue
          </button>
        </form>
      </div>

      <%!-- Human response (completed) --%>
      <div
        :if={@step.role == :human && @step.status == :done && @step.details != []}
        class="px-4 py-3"
      >
        <div class="space-y-0.5">
          <div :for={detail <- @step.details} class="font-mono text-xs text-base-content/50">
            {detail}
          </div>
        </div>
      </div>

      <%!-- Body --%>
      <div :if={@step.status in [:done, :failed] || @is_running || @diff} class="px-4 py-3 space-y-3">
        <%!-- Completion details: compact for done, full for failed --%>
        <div :if={@step.details != [] && @step.status == :done} class="flex items-baseline gap-2">
          <span class="font-mono text-xs text-base-content/40">
            {List.first(@step.details)}
          </span>
          <details :if={length(@step.details) > 1} class="inline group">
            <summary class="cursor-pointer font-mono text-[9px] tracking-wider uppercase text-base-content/25 hover:text-base-content/50">
              +{length(@step.details) - 1} more
            </summary>
            <div class="mt-1 space-y-0.5">
              <div :for={detail <- tl(@step.details)} class="font-mono text-xs text-base-content/35">
                {detail}
              </div>
            </div>
          </details>
        </div>
        <div :if={@step.details != [] && @step.status != :done} class="space-y-0.5">
          <div :for={detail <- @step.details} class="font-mono text-xs text-base-content/50">
            {detail}
          </div>
        </div>

        <%!-- Screenshots --%>
        <div :if={@step.screenshots != []} class="flex flex-wrap gap-2 pt-1">
          <a
            :for={shot <- @step.screenshots}
            href={~p"/images/#{shot.id}"}
            target="_blank"
            class="group relative block border border-base-content/10 hover:border-base-content/30 transition-colors"
          >
            <img
              src={~p"/images/#{shot.id}"}
              alt={shot.filename}
              class="h-32 w-auto object-cover"
              loading="lazy"
            />
            <span class="absolute bottom-0 left-0 right-0 bg-base-100/80 font-mono text-[9px] px-1.5 py-0.5 truncate opacity-0 group-hover:opacity-100 transition-opacity">
              {shot.filename}
            </span>
          </a>
        </div>

        <%!-- Agent output (live) --%>
        <div
          :if={@is_running && @agent_output != []}
          class="font-mono text-xs leading-relaxed max-h-64 overflow-y-auto p-3 bg-base-200/60"
          id={"step-output-#{@step.index}"}
          phx-hook="AutoScroll"
        >
          <div :for={line <- @agent_output} class={output_line_class(line)}>
            {line}
          </div>
        </div>
        <div
          :if={@is_running && @agent_output == []}
          class="font-mono text-xs italic text-base-content/30"
        >
          Starting...
        </div>

        <%!-- User notes sent to running agent --%>
        <div :if={@is_running && @user_notes != []} class="space-y-1 pt-2">
          <div
            :for={note <- @user_notes}
            class="font-mono text-xs text-base-content/50 pl-3 border-l-2 border-base-content/15"
          >
            <span class="text-base-content/30">you:</span> {note}
          </div>
        </div>

        <%!-- Chat input for running agent --%>
        <form :if={@is_running} phx-submit="send_note" class="flex gap-2 pt-2">
          <input type="hidden" name="task_id" value={@step.id} />
          <input
            type="text"
            name="message"
            placeholder="Add context..."
            class="flex-1 bg-transparent border border-base-content/15 px-2 py-1 font-mono text-xs focus:outline-none focus:border-base-content/40 placeholder:text-base-content/20"
            autocomplete="off"
          />
          <button
            type="submit"
            class="font-mono text-[9px] tracking-wider uppercase border border-base-content/20 px-2 py-1 hover:bg-base-content hover:text-base-100 transition-colors"
          >
            Send
          </button>
        </form>

        <%!-- Saved agent output (for completed steps) --%>
        <details :if={!@is_running && @saved_output && @saved_output != []} class="group">
          <summary class="cursor-pointer font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/30 hover:text-base-content">
            Agent output
          </summary>
          <div class="mt-2 font-mono text-xs leading-relaxed max-h-48 overflow-y-auto p-3 bg-base-200/50">
            <div
              :for={line <- @saved_output}
              class={output_line_class(line)}
            >
              {line}
            </div>
          </div>
        </details>

        <%!-- Load diff button if not yet loaded --%>
        <button
          :if={@step.status == :done && !@diff && @step.details != []}
          phx-click="load_diff"
          phx-value-index={@step.index}
          class="font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/30 hover:text-base-content transition-colors cursor-pointer"
        >
          Show diff
        </button>

        <%!-- Diff viewer --%>
        <div :if={@diff && is_list(@diff)} class="space-y-1">
          <details :for={file <- @diff} class="group border border-base-content/10">
            <summary class="flex items-center justify-between px-3 py-2 cursor-pointer hover:bg-base-200/50 transition-colors duration-100">
              <div class="flex items-center gap-2">
                <span class={[
                  "font-mono text-[9px] tracking-wider uppercase px-1 py-0.5 border",
                  file_status_style(file.status)
                ]}>
                  {file_status_label(file.status)}
                </span>
                <span class="font-mono text-xs">{file.path}</span>
              </div>
              <span class="font-mono text-[10px] text-base-content/30">
                <span class="text-green-500/70">+{elem(file.stats, 0)}</span>
                <span class="text-base-content/30 mx-1">/</span>
                <span class="text-red-400/70">-{elem(file.stats, 1)}</span>
              </span>
            </summary>
            <div class="border-t border-base-content/10 overflow-x-auto">
              <table class="w-full font-mono text-[11px] leading-tight">
                <tbody>
                  <tr :for={line <- file.lines} class={line_row_class(line.type)}>
                    <%= if line.type == :hunk_header do %>
                      <td
                        colspan="3"
                        class="px-3 py-1 text-base-content/30 bg-base-200/50 font-mono text-[10px]"
                      >
                        {line.content}
                      </td>
                    <% else %>
                      <td class="w-10 px-2 py-0 text-right text-base-content/20 select-none border-r border-base-content/5">
                        {line.old_num}
                      </td>
                      <td class="w-10 px-2 py-0 text-right text-base-content/20 select-none border-r border-base-content/5">
                        {line.new_num}
                      </td>
                      <td class="px-3 py-0 whitespace-pre-wrap">
                        <span class={["inline-block w-3 select-none", line_marker_class(line.type)]}>
                          {line_marker(line.type)}
                        </span>{line.content}
                      </td>
                    <% end %>
                  </tr>
                </tbody>
              </table>
            </div>
          </details>
        </div>
        <%!-- Legacy string diff fallback --%>
        <details :if={@diff && is_binary(@diff)} class="group">
          <summary class="cursor-pointer font-mono text-[10px] tracking-[0.2em] uppercase text-base-content/40 hover:text-base-content">
            Diff
          </summary>
          <div class="mt-2 border border-base-content/10 p-3 font-mono text-xs overflow-x-auto">
            <pre class="whitespace-pre-wrap text-base-content/70">{@diff}</pre>
          </div>
        </details>
      </div>
    </article>
    """
  end

  # ── Footer ─────────────────────────────────────────────────────

  defp btn_primary,
    do:
      "bg-base-content text-base-100 px-5 py-1.5 font-mono text-[10px] tracking-widest uppercase border border-base-content hover:bg-transparent hover:text-base-content transition-colors duration-100"

  defp btn_secondary,
    do:
      "px-5 py-1.5 font-mono text-[10px] tracking-widest uppercase border border-base-content hover:bg-base-content hover:text-base-100 transition-colors duration-100"

  defp footer_buttons(assigns) do
    assigns = Map.merge(assigns, %{pri: btn_primary(), sec: btn_secondary()})
    render_footer(assigns)
  end

  defp render_footer(%{state: :idle} = assigns) do
    ~H"""
    <div class="flex gap-1">
      <button phx-click="continue" class={@pri}>Start Planning</button>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">Idle</div>
    """
  end

  defp render_footer(%{state: :planning} = assigns) do
    ~H"""
    <div class="flex gap-1">
      <button phx-click="pause" class={@sec}>Pause</button>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      @planner running{format_elapsed(@agent_started_at)}
    </div>
    """
  end

  defp render_footer(%{state: :planning_done} = assigns) do
    ~H"""
    <div class="flex gap-1">
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      Plan ready — review and start above
    </div>
    """
  end

  defp render_footer(%{state: :cruising} = assigns) do
    ~H"""
    <div class="flex gap-1">
      <button phx-click="pause" class={@sec}>Pause</button>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      <span :if={@agent_role}>@{@agent_role} running{format_elapsed(@agent_started_at)}</span>
      <span :if={!@agent_role}>{@done}/{@total} — dispatching next...</span>
    </div>
    """
  end

  defp render_footer(%{state: :paused} = assigns) do
    ~H"""
    <div class="flex gap-1">
      <button phx-click="continue" class={@pri}>Resume</button>
      <button
        phx-click="stop_session"
        data-confirm="Stop this session? The agent will be killed."
        class={@sec}
      >
        Stop
      </button>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">Paused</div>
    """
  end

  defp render_footer(%{state: :stopped_human} = assigns) do
    ~H"""
    <div class="flex gap-1">
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      Waiting for your input above
    </div>
    """
  end

  defp render_footer(%{state: :stopped_error} = assigns) do
    ~H"""
    <div class="flex gap-1">
      <button
        phx-click="merge_into_main"
        data-confirm="Merge into main despite errors?"
        class={@sec}
      >
        Merge into Main
      </button>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      <span :if={!@merge_error}>Task failed — retry or skip above</span>
      <span :if={@merge_error} class="text-error">{@merge_error}</span>
    </div>
    """
  end

  defp render_footer(%{state: :stopped_loop_limit} = assigns) do
    ~H"""
    <div class="flex gap-1">
      <button phx-click="continue" class={@sec}>Force Resume</button>
      <button
        phx-click="merge_into_main"
        data-confirm="Merge into main despite loop limit?"
        class={@sec}
      >
        Merge into Main
      </button>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      <span :if={!@merge_error}>QA-dev loop limit — skip task above or force resume</span>
      <span :if={@merge_error} class="text-error">{@merge_error}</span>
    </div>
    """
  end

  defp render_footer(%{state: :merged} = assigns) do
    ~H"""
    <div class="flex gap-1">
      <a href={~p"/"} class={@pri}>New Session</a>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      Merged into main
    </div>
    """
  end

  defp render_footer(%{state: :complete} = assigns) do
    ~H"""
    <div class="flex gap-1">
      <button phx-click="create_pr" class={@pri}>Create PR</button>
      <button
        phx-click="merge_into_main"
        data-confirm="Merge into main and delete the worktree?"
        class={@sec}
      >
        Merge into Main
      </button>
      <a href={~p"/"} class={@sec}>New Session</a>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      <span :if={!@merge_error}>Complete</span>
      <span :if={@merge_error} class="text-error">{@merge_error}</span>
    </div>
    """
  end

  defp render_footer(assigns) do
    ~H"""
    <div class="flex gap-1">
      <button phx-click="continue" class={@pri}>Resume</button>
    </div>
    <div class="font-mono text-[10px] tracking-wider text-base-content/40 uppercase">
      {orchestrator_label(@state)}
    </div>
    """
  end

  # ── Events ───────────────────────────────────────────────────────

  @impl true
  def handle_event("continue", _params, socket) do
    Forge.Scheduler.resume(socket.assigns.session_id)
    {:noreply, socket}
  end

  def handle_event("pause", _params, socket) do
    Forge.Scheduler.pause(socket.assigns.session_id)
    {:noreply, socket}
  end

  def handle_event("stop_session", _params, socket) do
    Forge.Session.stop_session(socket.assigns.session_id)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("kill_session", _params, socket) do
    Forge.Session.delete_session(socket.assigns.session_id)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("skip", _params, socket) do
    # Skip the first planned task
    tasks = TaskEngine.list_tasks(socket.assigns.session_id)

    case Enum.find(tasks, &(&1.state in [:planned, :assigned])) do
      nil -> :ok
      task -> Forge.Scheduler.skip_task(socket.assigns.session_id, task.id)
    end

    {:noreply, socket}
  end

  def handle_event("retry", _params, socket) do
    # Retry the first failed task
    tasks = TaskEngine.list_tasks(socket.assigns.session_id)

    case Enum.find(tasks, &(&1.state == :failed)) do
      nil -> :ok
      task -> TaskEngine.retry_task(task)
    end

    Forge.Scheduler.resume(socket.assigns.session_id)
    {:noreply, socket}
  end

  def handle_event("restart_task", %{"id" => task_id}, socket) do
    session_id = socket.assigns.session_id
    # Synchronous kill — waits for agent to die and task to be marked :failed
    Forge.Scheduler.kill_task(session_id, task_id)

    # Now safely retry (:failed -> :planned)
    case Forge.Repo.get(Forge.Schemas.Task, task_id) do
      nil -> :ok
      task -> TaskEngine.retry_task(task)
    end

    Forge.Scheduler.resume(session_id)
    {:noreply, reload_tasks(socket)}
  end

  def handle_event("kill_task", %{"id" => task_id}, socket) do
    Forge.Scheduler.kill_task(socket.assigns.session_id, task_id)
    {:noreply, reload_tasks(socket)}
  end

  def handle_event("retry_task", %{"id" => task_id}, socket) do
    case Forge.Repo.get(Forge.Schemas.Task, task_id) do
      %{state: :failed} = task ->
        TaskEngine.retry_task(task)
        Forge.Scheduler.resume(socket.assigns.session_id)

      _ ->
        :ok
    end

    {:noreply, reload_tasks(socket)}
  end

  def handle_event("load_diff", %{"index" => index}, socket) do
    index = String.to_integer(index)
    workdir = socket.assigns.ask_workdir || "."

    # Find the task by sort_order
    step = Enum.find(socket.assigns.steps, &(&1.index == index))

    diffs =
      if step && step.details != [] do
        commit =
          step.details
          |> Enum.find_value(fn d ->
            case Regex.run(~r/commit:\s*([a-f0-9]+)/, d) do
              [_, hash] -> hash
              _ -> nil
            end
          end)

        if commit do
          Forge.DiffParser.diff_for_commit(workdir, commit)
        else
          Forge.DiffParser.diff_head(workdir)
        end
      else
        nil
      end

    if diffs do
      step_diffs = Map.put(socket.assigns.step_diffs, index, diffs)
      {:noreply, assign(socket, :step_diffs, step_diffs)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_step", %{"index" => index}, socket) do
    {:noreply, assign(socket, :editing_step, String.to_integer(index))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_step, nil)}
  end

  def handle_event("save_step", params, socket) do
    index = String.to_integer(params["index"])
    tasks = TaskEngine.list_tasks(socket.assigns.session_id)

    case Enum.find(tasks, &(&1.sort_order == index)) do
      nil ->
        :ok

      task ->
        attrs = %{title: String.trim(params["description"] || task.title)}

        attrs =
          if params["acceptance_criteria"],
            do: Map.put(attrs, :acceptance_criteria, String.trim(params["acceptance_criteria"])),
            else: attrs

        task |> Forge.Schemas.Task.changeset(attrs) |> Forge.Repo.update()
    end

    {:noreply, socket |> assign(:editing_step, nil) |> reload_tasks()}
  end

  def handle_event("delete_step", %{"index" => index}, socket) do
    index = String.to_integer(index)
    tasks = TaskEngine.list_tasks(socket.assigns.session_id)

    case Enum.find(tasks, &(&1.sort_order == index)) do
      nil -> :ok
      task -> Forge.Repo.delete(task)
    end

    {:noreply, reload_tasks(socket)}
  end

  def handle_event("submit_human", %{"task_id" => task_id, "response" => response}, socket) do
    response = String.trim(response)

    case Forge.Repo.get(Forge.Schemas.Task, task_id) do
      %{role: :human, state: s} = task when s in [:planned, :assigned] ->
        TaskEngine.transition(task, :done, %{"response" => response})
        Forge.Scheduler.resume(socket.assigns.session_id)

      _ ->
        :ok
    end

    {:noreply, reload_tasks(socket)}
  end

  def handle_event("send_note", %{"task_id" => task_id, "message" => message}, socket) do
    message = String.trim(message)

    if message != "" do
      session_id = socket.assigns.session_id
      Forge.Scheduler.send_message(session_id, task_id, message)

      notes = Map.update(socket.assigns.user_notes, task_id, [message], &(&1 ++ [message]))

      # Track planner notes separately for the planner card
      socket =
        if task_id == socket.assigns.running_task_id &&
             socket.assigns.orchestrator_state == :planning do
          assign(socket, :planner_notes, socket.assigns.planner_notes ++ [message])
        else
          socket
        end

      {:noreply, assign(socket, :user_notes, notes)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_task", %{"title" => title}, socket) do
    title = String.trim(title)

    if title != "" do
      session = Forge.Repo.get!(Forge.Schemas.Session, socket.assigns.session_id)

      TaskEngine.create_task(session, %{
        role: :dev,
        title: title,
        prompt: title
      })
    end

    {:noreply, reload_tasks(socket)}
  end

  def handle_event("planner_chat", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      session_id = socket.assigns.session_id

      # Delete all planned (not yet started) tasks
      TaskEngine.delete_planned_tasks(session_id)

      # Build enriched prompt with previous plan context
      previous_plan = socket.assigns.plan_markdown || ""

      prompt = """
      Original goal: #{socket.assigns.goal}

      Previous plan:
      #{previous_plan}

      User feedback: #{message}

      Revise the plan based on the user's feedback. Output the full updated plan and tasks.
      """

      # Create a new planner task with context
      session = Forge.Repo.get!(Forge.Schemas.Session, session_id)

      TaskEngine.create_task(session, %{
        role: :planner,
        title: "Re-plan: #{String.slice(message, 0, 50)}",
        prompt: prompt
      })

      # Resume scheduler so the planner can run
      Forge.Scheduler.resume(session_id)

      {:noreply, reload_tasks(socket)}
    end
  end

  def handle_event("replan", _params, socket) do
    session_id = socket.assigns.session_id

    # Delete all planned (not yet started) tasks
    TaskEngine.delete_planned_tasks(session_id)

    # Create a new planner task with the original goal
    session = Forge.Repo.get!(Forge.Schemas.Session, session_id)

    TaskEngine.create_task(session, %{
      role: :planner,
      title: "Re-plan: #{socket.assigns.goal}",
      prompt: socket.assigns.goal
    })

    # Resume scheduler so the planner can run
    Forge.Scheduler.resume(session_id)

    {:noreply, reload_tasks(socket)}
  end

  def handle_event("toggle_ask", _params, socket) do
    {:noreply, assign(socket, :ask_open, !socket.assigns.ask_open)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  def handle_event("new_session", _params, socket) do
    project_path = socket.assigns.project_path

    if project_path do
      {:noreply, push_navigate(socket, to: ~p"/?project=#{project_path}")}
    else
      {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  def handle_event("delete_session", %{"id" => session_id}, socket) do
    Forge.Session.delete_session(session_id)
    all_sessions = Forge.Session.list_sessions()
    projects = group_sessions(all_sessions)
    {:noreply, assign(socket, :projects, projects)}
  end

  def handle_event("toggle_shortcuts", _params, socket) do
    {:noreply, assign(socket, :show_shortcuts, !socket.assigns.show_shortcuts)}
  end

  def handle_event("ask_question", %{"question" => question}, socket) do
    question = String.trim(question)

    if question == "" || socket.assigns.ask_streaming do
      {:noreply, socket}
    else
      # Add user message
      messages = socket.assigns.ask_messages ++ [%{role: :user, content: question}]

      # Build prompt with project context and conversation history
      workdir = socket.assigns.ask_workdir || "."
      prompt = build_ask_prompt(question, workdir, socket.assigns.ask_messages)

      # Write prompt to temp file and spawn claude
      ask_dir = Path.join(workdir, ".forge")
      File.mkdir_p!(ask_dir)
      prompt_path = Path.join(ask_dir, "prompt-ask")
      File.write!(prompt_path, prompt)

      cmd =
        "cat '#{prompt_path}' | claude -p --dangerously-skip-permissions --output-format stream-json 2>&1"

      port =
        Port.open(
          {:spawn_executable, System.find_executable("bash")},
          [:binary, :exit_status, args: ["-c", cmd], cd: workdir]
        )

      {:noreply,
       socket
       |> assign(:ask_messages, messages)
       |> assign(:ask_port, port)
       |> assign(:ask_streaming, true)}
    end
  end

  def handle_event("cycle_automation", _params, socket) do
    next =
      case socket.assigns.automation do
        :manual -> :supervised
        :supervised -> :autopilot
        :autopilot -> :manual
      end

    Forge.Scheduler.set_automation(socket.assigns.session_id, next)
    {:noreply, assign(socket, :automation, next)}
  end

  def handle_event("create_pr", _params, socket) do
    case Forge.Session.create_pr(socket.assigns.session_id) do
      {:ok, pr_url} ->
        {:noreply, put_flash(socket, :info, "PR created: #{pr_url}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("merge_into_main", _params, socket) do
    case Forge.Session.merge_into_main(socket.assigns.session_id) do
      :ok ->
        projects = group_sessions(Forge.Session.list_sessions())

        {:noreply,
         socket
         |> assign(:orchestrator_state, :merged)
         |> assign(:projects, projects)
         |> assign(:page_title, page_title(:merged, nil, 0, 0))}

      {:error, reason} ->
        {:noreply, assign(socket, :merge_error, reason)}
    end
  end

  # ── PubSub ───────────────────────────────────────────────────────

  # ── PubSub: task events → reload from DB ──────────────────────

  @impl true
  def handle_info({event, _data}, socket)
      when event in [:task_created, :task_updated, :tasks_created] do
    {:noreply, reload_tasks(socket)}
  end

  # Agent output streaming (per-task)
  def handle_info({:agent_output, task_id, line}, socket) do
    # Track which task is producing output
    output = socket.assigns.agent_output ++ [line]
    output = if length(output) > 2000, do: Enum.take(output, -2000), else: output
    {:noreply, assign(socket, agent_output: output, running_task_id: task_id)}
  end

  # Agent setup progress (pre-spawn phases)
  def handle_info({:agent_setup, task_id, role, phase}, socket) do
    output = socket.assigns.agent_output ++ [":: #{phase}"]

    {:noreply,
     socket
     |> assign(
       agent_role: role,
       agent_output: output,
       agent_started_at: socket.assigns.agent_started_at || DateTime.utc_now(),
       running_task_id: task_id
     )
     |> assign(:orchestrator_state, if(role == :planner, do: :planning, else: :cruising))
     |> assign(
       :page_title,
       page_title(:cruising, role, socket.assigns.done, socket.assigns.total)
     )}
  end

  def handle_info({:agent_started, task_id, role}, socket) do
    {:noreply,
     socket
     |> assign(
       agent_role: role,
       running_task_id: task_id
     )
     |> assign(
       :page_title,
       page_title(:cruising, role, socket.assigns.done, socket.assigns.total)
     )}
  end

  def handle_info({:agent_finished, task_id, _role}, socket) do
    # Persist agent output to step_outputs before clearing
    step = Enum.find(socket.assigns.steps, &(&1.id == task_id))

    step_outputs =
      if step && socket.assigns.agent_output != [] do
        Map.put(socket.assigns.step_outputs, step.index, socket.assigns.agent_output)
      else
        socket.assigns.step_outputs
      end

    {:noreply,
     socket
     |> assign(:agent_role, nil)
     |> assign(:agent_started_at, nil)
     |> assign(:agent_output, [])
     |> assign(:running_task_id, nil)
     |> assign(:step_outputs, step_outputs)
     |> reload_tasks()}
  end

  def handle_info({:waiting_human, _task}, socket) do
    socket =
      socket
      |> assign(:orchestrator_state, :stopped_human)
      |> assign(
        :page_title,
        page_title(:stopped_human, nil, socket.assigns.done, socket.assigns.total)
      )
      |> maybe_notify(:stopped_human)

    {:noreply, socket}
  end

  def handle_info({:session_complete, _session_id}, socket) do
    socket =
      socket
      |> assign(:orchestrator_state, :complete)
      |> maybe_notify(:complete)

    {:noreply, socket}
  end

  def handle_info({:plan_updated, _session_id}, socket) do
    session = Forge.Repo.get(Forge.Schemas.Session, socket.assigns.session_id)
    plan_md = session && session.plan_markdown

    {:noreply,
     socket
     |> assign(:plan_markdown, plan_md)
     |> assign(:plan_html, Forge.PlanRenderer.render(plan_md))}
  end

  def handle_info({:scheduler_paused, _}, socket) do
    {:noreply, assign(socket, :orchestrator_state, :paused)}
  end

  def handle_info({:scheduler_resumed, _}, socket) do
    {:noreply, reload_tasks(socket)}
  end

  def handle_info({:cycle_limit_reached, _task_id, _role}, socket) do
    socket =
      socket
      |> assign(:orchestrator_state, :stopped_loop_limit)
      |> assign(
        :page_title,
        page_title(:stopped_loop_limit, nil, socket.assigns.done, socket.assigns.total)
      )

    {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    tick = (socket.assigns[:tick_count] || 0) + 1
    socket = assign(socket, :tick_count, tick)

    # Every 5 seconds, refresh from DB and check for stuck state
    socket =
      if rem(tick, 5) == 0 do
        socket = reload_tasks(socket)
        maybe_auto_recover(socket)
      else
        socket
      end

    # Force re-render for elapsed time display
    if socket.assigns.agent_started_at do
      {:noreply, assign(socket, :agent_started_at, socket.assigns.agent_started_at)}
    else
      {:noreply, socket}
    end
  end

  # Q&A port handlers
  def handle_info({port, {:data, data}}, %{assigns: %{ask_port: port}} = socket)
      when is_port(port) do
    text = parse_ask_output(data)

    if text && text != "" do
      messages = socket.assigns.ask_messages
      # Append to last assistant message or create new one
      messages =
        case List.last(messages) do
          %{role: :assistant, content: existing} ->
            List.replace_at(messages, -1, %{role: :assistant, content: existing <> text})

          _ ->
            messages ++ [%{role: :assistant, content: text}]
        end

      {:noreply, assign(socket, :ask_messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({port, {:exit_status, _status}}, %{assigns: %{ask_port: port}} = socket)
      when is_port(port) do
    # Clean up prompt file
    if workdir = socket.assigns.ask_workdir do
      File.rm(Path.join(workdir, ".forge/prompt-ask"))
    end

    {:noreply, assign(socket, ask_port: nil, ask_streaming: false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ──────────────────────────────────────────────────────

  # ── Q&A helpers ──────────────────────────────────────────────────

  defp build_ask_prompt(question, workdir, previous_messages) do
    # Read project conventions if available
    conventions =
      [Path.join(workdir, "CLAUDE.md"), Path.join(workdir, ".claude/CLAUDE.md")]
      |> Enum.find(&File.exists?/1)
      |> case do
        nil -> ""
        path -> "\n\nProject conventions:\n#{File.read!(path)}\n"
      end

    # Include conversation history for context continuity
    history =
      case previous_messages do
        [] ->
          ""

        msgs ->
          formatted =
            msgs
            |> Enum.take(-10)
            |> Enum.map_join("\n", fn
              %{role: :user, content: c} -> "User: #{c}"
              %{role: :assistant, content: c} -> "Assistant: #{c}"
            end)

          "\n\nConversation so far:\n#{formatted}\n"
      end

    """
    You are a read-only assistant for this codebase. Answer questions concisely.
    Do NOT modify any files. Only use Read, Grep, Glob, and Bash (for non-destructive commands like ls, git log, etc).
    #{conventions}#{history}
    Question: #{question}
    """
  end

  defp parse_ask_output(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => text}}} -> text
        {:ok, %{"type" => "assistant", "content" => content}} when is_binary(content) -> content
        {:ok, %{"type" => "result", "result" => result}} when is_binary(result) -> result
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp maybe_notify(socket, :stopped_human),
    do: push_event(socket, "notify", %{title: "Forge", body: "Human step — your turn"})

  defp maybe_notify(socket, :stopped_error),
    do: push_event(socket, "notify", %{title: "Forge", body: "Agent error — needs attention"})

  defp maybe_notify(socket, :complete),
    do: push_event(socket, "notify", %{title: "Forge", body: "All steps complete!"})

  defp maybe_notify(socket, _), do: socket

  defp is_running?(step, assigns) do
    step.id == assigns.running_task_id || step.status == :running
  end

  defp highlight_files(description) do
    # Highlight file paths like backend/src/foo/bar.ts in monospace
    Regex.replace(
      ~r/((?:backend|frontend|backoffice|src|lib)\/[\w\/.\-]+\.\w+)/,
      description,
      "<code class=\"font-mono text-[11px] bg-base-content/5 px-1\">\\1</code>"
    )
    |> Phoenix.HTML.raw()
  end

  defp group_sessions(sessions) do
    sessions
    |> Enum.map(fn s ->
      project = Map.get(s, :project_name) || Map.get(s, :repo_path, "unknown") |> Path.basename()
      {project, s}
    end)
    |> Enum.group_by(fn {p, _} -> p end, fn {_, s} -> s end)
    |> Enum.sort_by(fn {p, _} -> p end)
  end

  defp session_indicator(assigns) do
    ~H"""
    <%= cond do %>
      <% @s.failed > 0 -> %>
        <%!-- Error: blinking square --%>
        <div class="w-2 h-2 flex-shrink-0 border-2 border-base-content animate-attention" />
      <% @s.waiting_human > 0 -> %>
        <%!-- Needs human: hollow blinking circle --%>
        <div class="w-2 h-2 flex-shrink-0 rounded-full border-2 border-base-content animate-attention" />
      <% @s.done == @s.total and @s.total > 0 -> %>
        <%!-- Complete / ready to merge: blinking solid circle --%>
        <div class="w-2 h-2 flex-shrink-0 rounded-full bg-base-content animate-attention" />
      <% @s.in_progress > 0 -> %>
        <%!-- Running: marching-ants circle --%>
        <svg class="w-2.5 h-2.5 flex-shrink-0" viewBox="0 0 12 12">
          <circle
            cx="6"
            cy="6"
            r="4.5"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-dasharray="3 2"
            class="animate-march"
          />
        </svg>
      <% @s.done > 0 -> %>
        <%!-- Partial: half-filled dot --%>
        <div class="w-1.5 h-1.5 flex-shrink-0 bg-base-content/50" />
      <% true -> %>
        <%!-- Idle: hollow --%>
        <div class="w-1.5 h-1.5 flex-shrink-0 border border-base-content/30" />
    <% end %>
    """
  end

  defp page_title(:planning, _role, _done, _total), do: "Planning..."

  defp page_title(:cruising, role, done, total) when not is_nil(role),
    do: "@#{role} #{done}/#{total}"

  defp page_title(:cruising, _role, done, total), do: "#{done}/#{total}"
  defp page_title(:stopped_error, _role, _done, _total), do: "!! Error"
  defp page_title(:stopped_human, _role, _done, _total), do: ">> Your Turn"
  defp page_title(:stopped_loop_limit, _role, _done, _total), do: "Loop Limit"
  defp page_title(:merged, _role, _done, _total), do: "Merged"
  defp page_title(:complete, _role, done, total), do: "Done #{done}/#{total}"
  defp page_title(:paused, _role, _done, _total), do: "Paused"
  defp page_title(:planning_done, _role, _done, _total), do: "Plan Ready"
  defp page_title(_, _role, _done, _total), do: nil

  defp format_elapsed(nil), do: ""

  defp format_elapsed(started_at) do
    seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    if minutes > 0, do: " — #{minutes}m #{secs}s", else: " — #{secs}s"
  end

  defp orchestrator_label(:idle), do: "Idle"
  defp orchestrator_label(:planning), do: "Planning"
  defp orchestrator_label(:planning_done), do: "Plan Ready"
  defp orchestrator_label(:cruising), do: "Cruising"
  defp orchestrator_label(:paused), do: "Paused"
  defp orchestrator_label(:stopped_human), do: "Your Turn"
  defp orchestrator_label(:stopped_error), do: "Error"
  defp orchestrator_label(:stopped_loop_limit), do: "Loop Limit"
  defp orchestrator_label(:complete), do: "Complete"
  defp orchestrator_label(:merged), do: "Merged"
  defp orchestrator_label(state), do: state |> to_string() |> String.replace("_", " ")

  # ── Diff helpers ──────────────────────────────────────────────────

  defp file_status_style(:added), do: "border-base-content/40 text-base-content/60"
  defp file_status_style(:deleted), do: "border-base-content/60 text-base-content/80"
  defp file_status_style(:renamed), do: "border-base-content/30 text-base-content/50"
  defp file_status_style(_), do: "border-base-content/20 text-base-content/40"

  defp file_status_label(:added), do: "new"
  defp file_status_label(:deleted), do: "del"
  defp file_status_label(:renamed), do: "ren"
  defp file_status_label(_), do: "mod"

  defp line_row_class(:add), do: "bg-green-500/10"
  defp line_row_class(:remove), do: "bg-red-500/10"
  defp line_row_class(:hunk_header), do: ""
  defp line_row_class(_), do: ""

  defp line_marker(:add), do: "+"
  defp line_marker(:remove), do: "-"
  defp line_marker(_), do: " "

  defp line_marker_class(:add), do: "text-green-500 font-bold"
  defp line_marker_class(:remove), do: "text-red-400"
  defp line_marker_class(_), do: "text-base-content/15"

  defp strip_markdown(nil), do: ""
  defp strip_markdown(text), do: String.replace(text, ~r/\*+/, "")

  defp output_line_class(line) when is_binary(line) do
    base = "whitespace-pre-wrap break-all"

    cond do
      String.starts_with?(line, ":: ") -> "#{base} text-base-content/30 italic"
      String.starts_with?(line, "-> ") -> "#{base} text-base-content/50"
      String.starts_with?(line, "  ") -> "#{base} text-base-content/40"
      true -> "#{base} text-base-content/70"
    end
  end

  defp output_line_class(_), do: "whitespace-pre-wrap break-all text-base-content/70"

  # ── Data Adapters ──────────────────────────────────────────────

  defp task_to_step(%Forge.Schemas.Task{} = task) do
    details = format_task_result(task.result)

    status =
      case task.state do
        :done -> :done
        :failed -> :failed
        s when s in [:assigned, :in_progress] -> :running
        _ -> :todo
      end

    # Load screenshots for completed tasks
    screenshots =
      if task.state in [:done, :failed] do
        import Ecto.Query
        Forge.Repo.all(from i in Forge.Schemas.Image, where: i.task_id == ^task.id, select: %{id: i.id, filename: i.filename})
      else
        []
      end

    %{
      index: task.sort_order,
      id: task.id,
      state: task.state,
      status: status,
      role: task.role,
      description: task.title,
      prompt: task.prompt,
      acceptance_criteria: task.acceptance_criteria,
      details: details,
      screenshots: screenshots,
      tags: %{}
    }
  end

  defp format_task_result(nil), do: []

  defp format_task_result(%{"result" => summary} = result) do
    lines = [summary]
    commits = Map.get(result, "commits", [])
    lines ++ Enum.map(commits, &"commit: #{&1}")
  end

  defp format_task_result(%{"summary" => summary} = result) do
    passed = Map.get(result, "passed")
    verdict = if passed, do: "VERDICT: LGTM", else: "VERDICT: NEEDS_FIXES"
    issues = Map.get(result, "issues", [])
    [verdict, summary] ++ Enum.map(issues, &"  - #{&1}")
  end

  defp format_task_result(%{"response" => response}), do: ["Response: #{response}"]
  defp format_task_result(%{"auto_approved" => true}), do: ["Auto-approved"]
  defp format_task_result(%{"skipped" => true}), do: ["Skipped"]
  defp format_task_result(%{"raw" => raw}), do: [raw]
  defp format_task_result(_), do: []

  defp derive_orchestrator_state(tasks, session) do
    has_planner_running =
      Enum.any?(tasks, &(&1.role == :planner and &1.state in [:assigned, :in_progress]))

    has_running = Enum.any?(tasks, &(&1.state in [:assigned, :in_progress]))
    has_planned = Enum.any?(tasks, &(&1.state == :planned))
    planner_done = Enum.any?(tasks, &(&1.role == :planner and &1.state == :done))
    only_planner = tasks != [] and Enum.all?(tasks, &(&1.role == :planner))

    # Has any non-planner work completed? If so, execution has started.
    has_started =
      Enum.any?(tasks, fn t -> t.role != :planner and t.state in [:done, :failed] end)

    # Failed tasks that have child tasks (fix cycles) are "resolved" — don't block completion
    has_unresolved_failure =
      Enum.any?(tasks, fn task ->
        task.state == :failed and
          not Enum.any?(tasks, fn t -> t.parent_task_id == task.id end)
      end)

    all_terminal =
      tasks != [] and
        Enum.all?(tasks, &(&1.state in [:done, :failed]))

    all_done = all_terminal and not has_unresolved_failure
    autopilot = session.automation == :autopilot

    cond do
      session.state == :paused -> :paused
      has_planner_running -> :planning
      # Plan review: only when planner just finished and no work has started yet
      planner_done and only_planner and not autopilot -> :planning_done
      has_running -> :cruising
      has_unresolved_failure -> :stopped_error
      all_done -> :complete
      # Fresh plan, no work started yet — show plan review
      has_planned and not autopilot and not has_started -> :planning_done
      # Work already underway with remaining tasks — scheduler should be dispatching
      has_planned -> :cruising
      true -> :idle
    end
  end

  defp current_agent_role(tasks) do
    case Enum.find(tasks, &(&1.state == :in_progress)) do
      nil -> nil
      task -> task.role
    end
  end

  defp reload_tasks(socket) do
    session_id = socket.assigns.session_id
    tasks = TaskEngine.list_tasks(session_id)
    {done, total} = TaskEngine.progress(session_id)
    steps = Enum.map(tasks, &task_to_step/1)
    session = Forge.Repo.get(Forge.Schemas.Session, session_id)
    orch_state = derive_orchestrator_state(tasks, session)
    plan_md = session && session.plan_markdown

    socket
    |> assign(:steps, steps)
    |> assign(:done, done)
    |> assign(:total, total)
    |> assign(:orchestrator_state, orch_state)
    |> assign(:agent_role, current_agent_role(tasks))
    |> assign(:plan_markdown, plan_md)
    |> assign(:plan_html, Forge.PlanRenderer.render(plan_md))
    |> assign(:page_title, page_title(orch_state, current_agent_role(tasks), done, total))
    |> maybe_notify(orch_state)
  end

  # Detect stuck sessions and auto-recover.
  # Stuck = :cruising with no agent actually running, or scheduler is dead.
  defp maybe_auto_recover(socket) do
    session_id = socket.assigns.session_id
    orch_state = socket.assigns.orchestrator_state

    cond do
      # Cruising but nothing actually running — scheduler is stuck
      orch_state == :cruising and socket.assigns.agent_role == nil ->
        if Forge.Scheduler.alive?(session_id) do
          Forge.Scheduler.resume(session_id)
        else
          Forge.Session.ensure_running(session_id)
        end

        socket

      # Active session but scheduler is dead — restart it
      orch_state in [:planning, :cruising] and not Forge.Scheduler.alive?(session_id) ->
        Forge.Session.ensure_running(session_id)
        socket

      true ->
        socket
    end
  end
end
