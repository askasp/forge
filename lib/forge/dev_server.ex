defmodule Forge.DevServer do
  @moduledoc """
  Manages a dev server process per session. Starts the project's dev_start command
  in the worktree directory and polls until the server is ready.
  """
  use GenServer, restart: :temporary
  require Logger

  @ready_poll_interval_ms 1_000
  @ready_timeout_ms 30_000

  defstruct [:session_id, :port, :workdir, :cmd, url: nil, ready: false]

  # ── Client API ───────────────────────────────────────────────────

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Forge.SessionRegistry, {:dev_server, session_id}}}
    )
  end

  @doc "Ensure the dev server is started and ready. Returns :ok or {:error, reason}."
  def ensure_ready(session_id, url, timeout \\ @ready_timeout_ms) do
    case lookup(session_id) do
      nil ->
        {:error, "Dev server not configured for this session"}

      pid ->
        GenServer.call(pid, {:ensure_ready, url, timeout}, timeout + 5_000)
    end
  end

  @doc "Stop the dev server."
  def stop(session_id) do
    case lookup(session_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  @doc "Check if a dev server is running for this session."
  def running?(session_id) do
    lookup(session_id) != nil
  end

  defp lookup(session_id) do
    case Registry.lookup(Forge.SessionRegistry, {:dev_server, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # ── Server ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workdir = Keyword.fetch!(opts, :workdir)
    cmd = Keyword.fetch!(opts, :dev_start)

    state = %__MODULE__{
      session_id: session_id,
      workdir: workdir,
      cmd: cmd
    }

    # Start the dev server immediately
    send(self(), :start_server)

    {:ok, state}
  end

  @impl true
  def handle_info(:start_server, state) do
    Logger.info("[DevServer] Starting '#{state.cmd}' in #{state.workdir}")

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          args: ["-c", state.cmd],
          cd: state.workdir
        ]
      )

    {:noreply, %{state | port: port}}
  end

  def handle_info({port, {:data, _data}}, %{port: port} = state) do
    # Consume dev server output silently
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[DevServer] Dev server exited with status #{status}")
    {:noreply, %{state | port: nil, ready: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:ensure_ready, url, timeout}, _from, state) do
    if state.ready do
      {:reply, :ok, state}
    else
      case poll_until_ready(url, timeout) do
        :ok ->
          Logger.info("[DevServer] Server ready at #{url}")
          {:reply, :ok, %{state | ready: true, url: url}}

        {:error, _} = err ->
          {:reply, err, state}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      Logger.info("[DevServer] Stopping dev server for session #{state.session_id}")

      # Kill the process group
      try do
        {:os_pid, os_pid} = Port.info(state.port, :os_pid)
        # Kill the entire process group
        System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true)
      rescue
        _ -> :ok
      end

      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # ── Private ──────────────────────────────────────────────────────

  defp poll_until_ready(url, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(url, deadline)
  end

  defp do_poll(url, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, "Dev server not ready after timeout"}
    else
      case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 2_000], []) do
        {:ok, {{_, status, _}, _, _}} when status in 200..399 ->
          :ok

        _ ->
          Process.sleep(@ready_poll_interval_ms)
          do_poll(url, deadline)
      end
    end
  end
end
