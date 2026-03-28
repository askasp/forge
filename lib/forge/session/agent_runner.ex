defmodule Forge.Session.AgentRunner do
  @moduledoc """
  Manages a single claude -p invocation for one task.
  Started by the Scheduler, reports results back via direct message.
  Streams output to PubSub for LiveView display.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Forge.TaskEngine

  # No output for 5 minutes = stalled
  @activity_timeout_ms 5 * 60 * 1000
  # 30 minutes total = runaway
  @total_timeout_ms 30 * 60 * 1000
  # Check every 30 seconds
  @check_interval_ms 30_000

  defstruct [
    :session_id,
    :task,
    :scheduler,
    :workdir,
    :port,
    :agent_run_id,
    :started_at,
    :prompt,
    started_at_mono: nil,
    last_activity_at: nil,
    output: [],
    buffer: "",
    tool_blocks: %{},
    final_result: nil
  ]

  # ── Client API ───────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # ── Server ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    task = Keyword.fetch!(opts, :task)
    prompt = Keyword.fetch!(opts, :prompt)
    scheduler = Keyword.fetch!(opts, :scheduler)
    workdir = Keyword.fetch!(opts, :workdir)
    session_id = Keyword.fetch!(opts, :session_id)
    agent_run_id = Keyword.fetch!(opts, :agent_run_id)

    now_mono = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      session_id: session_id,
      task: task,
      scheduler: scheduler,
      workdir: workdir,
      prompt: prompt,
      agent_run_id: agent_run_id,
      started_at: DateTime.utc_now(),
      started_at_mono: now_mono,
      last_activity_at: now_mono
    }

    # Start the agent immediately
    send(self(), :start_agent)

    # Start timeout monitoring
    Process.send_after(self(), :check_timeout, @check_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:start_agent, state) do
    # Write prompt to temp file
    broadcast_output(state, ":: writing prompt file")
    forge_dir = Path.join(state.workdir, ".forge")
    File.mkdir_p!(forge_dir)
    prompt_path = Path.join(forge_dir, "prompt-#{state.task.role}")
    File.write!(prompt_path, state.prompt)

    # Write MCP config
    broadcast_output(state, ":: configuring MCP")
    write_mcp_settings(state.workdir, state.session_id)

    # Spawn claude -p with stream-json for live output
    broadcast_output(state, ":: starting claude cli")

    cmd =
      "cat '#{prompt_path}' | claude -p --verbose --dangerously-skip-permissions --output-format stream-json 2>&1"

    Logger.info("[AgentRunner] @#{state.task.role} task=#{state.task.id} in #{state.workdir}")

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          args: ["-c", cmd],
          cd: state.workdir
        ]
      )

    # Transition task to in_progress
    TaskEngine.transition(state.task, :in_progress)

    {:noreply, %{state | port: port}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = %{state | last_activity_at: System.monotonic_time(:millisecond)}
    combined = state.buffer <> data

    segments = String.split(combined, "\n")

    {complete_lines, new_buffer} =
      if String.ends_with?(data, "\n") do
        {Enum.reject(segments, &(&1 == "")), ""}
      else
        {complete, [partial]} = Enum.split(segments, -1)
        {Enum.reject(complete, &(&1 == "")), partial}
      end

    state =
      Enum.reduce(complete_lines, %{state | buffer: new_buffer}, fn line, acc ->
        {readable, new_acc} = parse_stream_json(line, acc)

        if readable do
          # Broadcast to LiveView via PubSub
          Phoenix.PubSub.broadcast(
            Forge.PubSub,
            "session:#{acc.session_id}",
            {:agent_output, acc.task.id, readable}
          )
        end

        output = [line | new_acc.output]
        output = if length(output) > 5000, do: Enum.take(output, 5000), else: output
        %{new_acc | output: output}
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("[AgentRunner] @#{state.task.role} exited with status #{status}")
    cleanup(state)

    # Extract structured JSON from the final result
    structured = extract_structured_output(state)

    # Complete the agent run record
    stdout = state.output |> Enum.reverse() |> Enum.join("\n")

    TaskEngine.complete_agent_run(state.agent_run_id, %{
      exit_code: status,
      stdout_log: stdout,
      structured_output: structured
    })

    # Notify scheduler directly
    send(
      state.scheduler,
      {:agent_done, state.task.id,
       %{
         exit_code: status,
         structured_output: structured
       }}
    )

    # Broadcast for LiveView
    Phoenix.PubSub.broadcast(
      Forge.PubSub,
      "session:#{state.session_id}",
      {:agent_finished, state.task.id, state.task.role}
    )

    {:stop, :normal, state}
  end

  def handle_info(:check_timeout, %{port: nil} = state) do
    # Port already exited, nothing to check
    {:noreply, state}
  end

  def handle_info(:check_timeout, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      now - state.started_at_mono > @total_timeout_ms ->
        Logger.warning("[AgentRunner] Total timeout for task #{state.task.id}")
        timeout_and_fail(state, "Agent timed out after #{div(@total_timeout_ms, 60_000)} minutes")

      now - state.last_activity_at > @activity_timeout_ms ->
        Logger.warning("[AgentRunner] Activity timeout for task #{state.task.id}")

        timeout_and_fail(
          state,
          "Agent stalled — no output for #{div(@activity_timeout_ms, 60_000)} minutes"
        )

      true ->
        Process.send_after(self(), :check_timeout, @check_interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[AgentRunner] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp timeout_and_fail(state, reason) do
    broadcast_output(state, "!! #{reason}")

    # Kill the port
    if state.port do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end

    # Complete agent run record
    stdout = state.output |> Enum.reverse() |> Enum.join("\n")

    TaskEngine.complete_agent_run(state.agent_run_id, %{
      exit_code: -1,
      stdout_log: stdout,
      structured_output: %{"error" => reason}
    })

    # Notify scheduler
    send(state.scheduler, {:agent_done, state.task.id, %{exit_code: -1, error: reason}})

    # Broadcast finish
    Phoenix.PubSub.broadcast(
      Forge.PubSub,
      "session:#{state.session_id}",
      {:agent_finished, state.task.id, state.task.role}
    )

    cleanup(state)
    {:stop, :normal, %{state | port: nil}}
  end

  # ── Stream JSON Parser ─────────────────────────────────────────

  defp parse_stream_json(line, state) do
    case Jason.decode(line) do
      {:ok,
       %{
         "type" => "content_block_start",
         "index" => idx,
         "content_block" => %{"type" => "tool_use", "name" => name}
       }} ->
        tool_blocks =
          Map.put(state.tool_blocks, idx, %{
            name: name,
            input_json: "",
            hint_sent: false,
            started_at: System.monotonic_time(:millisecond)
          })

        {tool_hint(name), %{state | tool_blocks: tool_blocks}}

      {:ok,
       %{
         "type" => "content_block_start",
         "content_block" => %{"type" => "thinking"}
       }} ->
        {":: thinking...", state}

      {:ok, %{"type" => "content_block_start"}} ->
        {nil, state}

      {:ok,
       %{
         "type" => "content_block_delta",
         "index" => idx,
         "delta" => %{"type" => "input_json_delta", "partial_json" => json}
       }} ->
        case Map.get(state.tool_blocks, idx) do
          %{input_json: existing, name: name, hint_sent: hint_sent} = block ->
            new_json = existing <> json
            updated_block = %{block | input_json: new_json}

            # Try to extract early detail (file path, command, etc.) before tool completes
            {early_hint, updated_block} =
              if hint_sent do
                {nil, updated_block}
              else
                case extract_early_detail(name, new_json) do
                  nil -> {nil, updated_block}
                  detail -> {detail, %{updated_block | hint_sent: true}}
                end
              end

            tool_blocks = Map.put(state.tool_blocks, idx, updated_block)
            {early_hint, %{state | tool_blocks: tool_blocks}}

          nil ->
            {nil, state}
        end

      {:ok, %{"type" => "content_block_delta", "delta" => %{"type" => "thinking_delta"}}} ->
        {nil, state}

      {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => text}}} ->
        {text, state}

      {:ok, %{"type" => "content_block_stop", "index" => idx}} ->
        case Map.pop(state.tool_blocks, idx) do
          {%{name: name, input_json: json, started_at: started_at}, remaining_blocks} ->
            elapsed_ms = System.monotonic_time(:millisecond) - started_at
            summary = format_tool_summary(name, json)

            summary =
              if elapsed_ms > 1000,
                do: "#{summary} (#{div(elapsed_ms, 1000)}s)",
                else: summary

            {summary, %{state | tool_blocks: remaining_blocks}}

          {%{name: name, input_json: json}, remaining_blocks} ->
            summary = format_tool_summary(name, json)
            {summary, %{state | tool_blocks: remaining_blocks}}

          {nil, _} ->
            {nil, state}
        end

      {:ok, %{"type" => "result", "result" => result}} when is_binary(result) ->
        {result, %{state | final_result: result}}

      {:ok, %{"type" => "result", "subtype" => "success", "result" => result}}
      when is_binary(result) ->
        {result, %{state | final_result: result}}

      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
      when is_list(content) ->
        text =
          content
          |> Enum.map(fn
            %{"type" => "text", "text" => t} -> t
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {if(text == "", do: nil, else: text), state}

      {:ok, %{"type" => "assistant", "content" => content}}
      when is_binary(content) and content != "" ->
        {content, state}

      {:ok, decoded} ->
        type = decoded["type"] || "unknown"
        subtype = decoded["subtype"]

        readable =
          cond do
            is_binary(decoded["content"]) and decoded["content"] != "" -> decoded["content"]
            is_binary(decoded["result"]) -> decoded["result"]
            subtype == "tool_use" -> format_tool_summary(decoded["name"] || "tool", "{}")
            type == "tool_result" -> nil
            true -> nil
          end

        # Capture result if present
        new_state =
          if is_binary(decoded["result"]) and decoded["result"] != "" do
            %{state | final_result: decoded["result"]}
          else
            state
          end

        {readable, new_state}

      {:error, _} ->
        text = if String.trim(line) != "", do: line
        {text, state}
    end
  end

  # ── Structured Output Extraction ───────────────────────────────

  defp extract_structured_output(state) do
    text = state.final_result || ""

    # Try to parse the entire result as JSON
    case Jason.decode(text) do
      {:ok, parsed} ->
        parsed

      {:error, _} ->
        # Try to find a JSON block in the text (```json ... ``` or { ... })
        case extract_json_block(text) do
          {:ok, parsed} -> parsed
          :error -> %{"raw" => text}
        end
    end
  end

  defp extract_json_block(text) do
    # Try fenced code block first
    case Regex.run(~r/```(?:json)?\s*\n([\s\S]*?)\n```/, text) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, parsed} -> {:ok, parsed}
          _ -> try_bare_json(text)
        end

      nil ->
        try_bare_json(text)
    end
  end

  defp try_bare_json(text) do
    # Try to find a JSON object or array
    trimmed = String.trim(text)

    cond do
      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        case Jason.decode(trimmed) do
          {:ok, parsed} -> {:ok, parsed}
          _ -> :error
        end

      true ->
        :error
    end
  end

  # ── Tool Formatting ────────────────────────────────────────────

  defp tool_hint("Read"), do: "  reading..."
  defp tool_hint("Bash"), do: "  running command..."
  defp tool_hint("Grep"), do: "  searching..."
  defp tool_hint("Glob"), do: "  finding files..."
  defp tool_hint("Edit"), do: "  editing..."
  defp tool_hint("Write"), do: "  writing..."
  defp tool_hint("Agent"), do: "  spawning agent..."
  defp tool_hint("WebSearch"), do: "  searching web..."
  defp tool_hint(name), do: "  #{name}..."

  defp format_tool_summary(name, input_json) do
    input =
      case Jason.decode(input_json) do
        {:ok, parsed} -> parsed
        _ -> %{}
      end

    case name do
      "Read" ->
        path = input["file_path"] || "?"
        "-> Read #{shorten_path(path)}"

      "Edit" ->
        path = input["file_path"] || "?"
        "-> Edit #{shorten_path(path)}"

      "Write" ->
        path = input["file_path"] || "?"
        "-> Write #{shorten_path(path)}"

      "Bash" ->
        cmd = input["command"] || "?"
        "-> $ #{truncate(cmd, 120)}"

      "Grep" ->
        pattern = input["pattern"] || "?"
        path = input["path"]
        if path, do: "-> Grep #{pattern} in #{shorten_path(path)}", else: "-> Grep #{pattern}"

      "Glob" ->
        pattern = input["pattern"] || "?"
        "-> Glob #{pattern}"

      "Agent" ->
        desc = input["description"] || input["prompt"]
        if desc, do: "-> Agent: #{truncate(desc, 80)}", else: "-> Agent"

      "WebSearch" ->
        query = input["query"] || "?"
        "-> Search: #{truncate(query, 80)}"

      "WebFetch" ->
        url = input["url"] || "?"
        "-> Fetch #{truncate(url, 80)}"

      tool ->
        case Map.to_list(input) do
          [] ->
            "-> #{tool}"

          [{_k, v}] when is_binary(v) ->
            "-> #{tool}: #{truncate(v, 80)}"

          pairs ->
            summary =
              pairs
              |> Enum.take(2)
              |> Enum.map(fn {k, v} -> "#{k}=#{truncate(to_string(v), 40)}" end)
              |> Enum.join(" ")

            "-> #{tool} #{summary}"
        end
    end
  end

  defp shorten_path(path) do
    parts = String.split(path, "/")

    if length(parts) > 3 do
      ".../" <> (parts |> Enum.take(-3) |> Enum.join("/"))
    else
      path
    end
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."

  # ── Early Tool Detail Extraction ────────────────────────────────

  defp extract_early_detail("Read", partial_json) do
    case Regex.run(~r/"file_path"\s*:\s*"([^"]+)"/, partial_json) do
      [_, path] -> "  reading #{shorten_path(path)}"
      _ -> nil
    end
  end

  defp extract_early_detail("Edit", partial_json) do
    case Regex.run(~r/"file_path"\s*:\s*"([^"]+)"/, partial_json) do
      [_, path] -> "  editing #{shorten_path(path)}"
      _ -> nil
    end
  end

  defp extract_early_detail("Write", partial_json) do
    case Regex.run(~r/"file_path"\s*:\s*"([^"]+)"/, partial_json) do
      [_, path] -> "  writing #{shorten_path(path)}"
      _ -> nil
    end
  end

  defp extract_early_detail("Bash", partial_json) do
    case Regex.run(~r/"command"\s*:\s*"([^"]{1,80})/, partial_json) do
      [_, cmd] -> "  $ #{cmd}"
      _ -> nil
    end
  end

  defp extract_early_detail("Grep", partial_json) do
    case Regex.run(~r/"pattern"\s*:\s*"([^"]+)"/, partial_json) do
      [_, pattern] -> "  searching for #{pattern}"
      _ -> nil
    end
  end

  defp extract_early_detail("Glob", partial_json) do
    case Regex.run(~r/"pattern"\s*:\s*"([^"]+)"/, partial_json) do
      [_, pattern] -> "  finding #{pattern}"
      _ -> nil
    end
  end

  defp extract_early_detail(_, _), do: nil

  # ── Broadcast Helper ──────────────────────────────────────────

  defp broadcast_output(state, text) do
    Phoenix.PubSub.broadcast(
      Forge.PubSub,
      "session:#{state.session_id}",
      {:agent_output, state.task.id, text}
    )
  end

  # ── Private ────────────────────────────────────────────────────

  defp cleanup(state) do
    forge_dir = Path.join(state.workdir, ".forge")
    File.rm(Path.join(forge_dir, "prompt-#{state.task.role}"))
  end

  defp write_mcp_settings(workdir, session_id) do
    port =
      try do
        {:ok, {_ip, actual_port}} = ForgeWeb.Endpoint.server_info(:http)
        actual_port
      rescue
        _ ->
          http_config = Application.get_env(:forge, ForgeWeb.Endpoint)[:http] || []
          Keyword.get(http_config, :port, 4000)
      end

    mcp_path = forge_mcp_path()

    claude_dir = Path.join(workdir, ".claude")
    File.mkdir_p!(claude_dir)
    settings_path = Path.join(claude_dir, "settings.local.json")

    main_settings_path =
      workdir
      |> String.replace(~r/\.worktrees\/.*$/, ".claude/settings.local.json")

    existing =
      cond do
        File.exists?(settings_path) ->
          case Jason.decode(File.read!(settings_path)) do
            {:ok, data} -> data
            _ -> %{}
          end

        File.exists?(main_settings_path) ->
          case Jason.decode(File.read!(main_settings_path)) do
            {:ok, data} -> data
            _ -> %{}
          end

        true ->
          %{}
      end

    mcp_servers = Map.get(existing, "mcpServers", %{})

    updated_mcp =
      Map.put(mcp_servers, "forge", %{
        "command" => mcp_path,
        "args" => ["--url", "http://localhost:#{port}", "--session", session_id]
      })

    settings = Map.put(existing, "mcpServers", updated_mcp)
    File.write!(settings_path, Jason.encode!(settings, pretty: true))
  end

  defp forge_mcp_path do
    candidates = [
      Path.join([File.cwd!(), "bin", "forge-mcp"]),
      Path.expand("../../../bin/forge-mcp", Application.app_dir(:forge, "priv"))
    ]

    Enum.find(candidates, List.first(candidates), &File.exists?/1)
  end
end
