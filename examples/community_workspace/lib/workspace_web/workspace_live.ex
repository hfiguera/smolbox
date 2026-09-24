defmodule WorkspaceWeb.WorkspaceLive do
  use Phoenix.LiveView
  alias Workspace.{TerminalSession, Workspaces}

  def mount(_params, _session, socket) do
    if connected?(socket), do: send(self(), :refresh)

    {:ok,
     socket
     |> assign(
       snapshot: nil,
       error: nil,
       busy: false,
       refreshing: false,
       notice: nil,
       terminal_warning: false,
       announcement: "",
       logs: nil,
       terminal: nil,
       terminal_status: :closed,
       confirming_delete: false,
       confirming_disconnect: false,
       confirming_cancel: nil,
       command: "pwd; ls -lah; cat starts.txt",
       cwd: "/app/project",
       mode: "foreground",
       timeout: "30",
       upload_path: "/app/project/notes.txt",
       download_path: "/app/project/starts.txt",
       token: Ecto.UUID.generate()
     )
     |> allow_upload(:file,
       accept: :any,
       max_entries: 1,
       max_file_size: Workspace.Settings.max_file_bytes()
     )}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 1000)

    if socket.assigns.refreshing do
      {:noreply, socket}
    else
      {:noreply,
       socket |> assign(:refreshing, true) |> start_async(:snapshot, &Workspaces.snapshot/0)}
    end
  end

  def handle_info({:terminal_ready, pid, resumed}, socket),
    do:
      {:noreply,
       socket
       |> assign(terminal: pid, terminal_status: :connected, terminal_warning: false, notice: nil)
       |> push_event("terminal-ready", %{resumed: resumed})}

  def handle_info({:terminal_output, seq, bytes}, socket),
    do: {:noreply, push_event(socket, "terminal-output", %{seq: seq, bytes: bytes})}

  def handle_info({:terminal_closed, outcome}, socket) do
    message =
      case outcome do
        {:ok, %{exit_code: code}} ->
          "Terminal exited with code #{code}."

        _ ->
          "Terminal disconnected. Check the recorded outcome before starting more work; disconnection does not prove guest termination."
      end

    {:noreply,
     socket
     |> assign(
       terminal: nil,
       terminal_status: :closed,
       notice: message,
       confirming_disconnect: false,
       terminal_warning: !match?({:ok, %{exit_code: _}}, outcome)
     )
     |> push_event("terminal-closed", %{message: message})
     |> push_event("new-intent", %{form: "terminal-form"})}
  end

  def handle_async(:snapshot, {:ok, {:ok, snapshot}}, socket) do
    announcement = announcement(socket.assigns.snapshot, snapshot)

    {:noreply,
     socket
     |> assign(
       snapshot: snapshot,
       refreshing: false,
       announcement: announcement || socket.assigns.announcement,
       error: if(snapshot.connection == :ready, do: nil, else: snapshot.connection)
     )
     |> reconcile_terminal_notice()
     |> reconnect_terminal()}
  end

  def handle_async(:snapshot, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, refreshing: false, error: reason)}

  def handle_async(:snapshot, {:exit, _}, socket),
    do: {:noreply, assign(socket, refreshing: false, error: :unavailable)}

  def handle_async(:mutation, {:ok, {:ok, :already_recorded}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         notice:
           "This lifecycle request was already recorded. It was not sent again. Inspect the machine state; an interrupted acceptance may need operator recovery."
       )}

  def handle_async(:mutation, {:ok, {:ok, _}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         notice: "Request recorded. Follow its outcome below.",
         confirming_delete: false
       )}

  def handle_async(:mutation, {:ok, error}, socket),
    do: {:noreply, assign(socket, busy: false, notice: error_message(error))}

  def handle_async(:mutation, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         notice:
           "The response was interrupted. Inspect the recorded request; do not repeat uncertain work under a new identity."
       )}

  def handle_async(:logs, {:ok, {:ok, result}}, socket),
    do: {:noreply, assign(socket, logs: Enum.join(result.lines, "\n"))}

  def handle_async(:logs, _, socket),
    do:
      {:noreply,
       assign(socket,
         logs: "Console diagnostics are unavailable. This does not establish machine absence."
       )}

  def handle_event("create", _, socket), do: mutate(socket, &Workspaces.create/0)

  def handle_event(action, _, socket) when action in ["start", "stop", "delete"] do
    id = workspace_id(socket)
    op = %{"start" => :start, "stop" => :stop, "delete" => :delete}[action]
    token = Ecto.UUID.generate()

    if action == "delete" and not socket.assigns.confirming_delete,
      do: {:noreply, assign(socket, :confirming_delete, true)},
      else: mutate(socket, fn -> Workspaces.lifecycle(op, id, token) end)
  end

  def handle_event("keep", _, socket), do: {:noreply, assign(socket, :confirming_delete, false)}

  def handle_event("command", params, socket) do
    id = workspace_id(socket)
    mutate(socket, fn -> Workspaces.command(id, params["token"], params) end)
  end

  def handle_event("change-command", params, socket) do
    {:noreply,
     assign(socket,
       command: params["command"],
       cwd: params["workdir"],
       mode: params["mode"],
       timeout: params["timeout"]
     )}
  end

  def handle_event("restore-intent", %{"form" => form, "token" => token}, socket) do
    kind =
      %{"command-form" => "command", "upload-form" => "upload", "download-form" => "download"}[
        form
      ]

    fields =
      if kind do
        case Workspaces.intent(token, kind) do
          {:ok, payload} -> Map.take(payload, ~w(command workdir mode timeout path))
          _ -> %{}
        end
      else
        %{}
      end

    {:reply, %{fields: fields}, socket}
  end

  def handle_event("new-command", _, socket),
    do: {:noreply, push_event(socket, "new-intent", %{form: "command-form"})}

  def handle_event("sample", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {number, ""} when number in 0..3 ->
        {_, command, mode, timeout} = Enum.at(Workspace.Sample.commands(), number)

        {:noreply,
         socket
         |> assign(command: command, cwd: "/app/project", mode: mode, timeout: to_string(timeout))
         |> push_event("new-intent", %{form: "command-form"})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("file-change", params, socket),
    do: {:noreply, assign(socket, :upload_path, params["path"] || socket.assigns.upload_path)}

  def handle_event("upload", params, socket) do
    id = workspace_id(socket)

    case consume_uploaded_entries(socket, :file, fn %{path: path}, _ ->
           {:ok, File.read!(path)}
         end) do
      [bytes] ->
        mutate(socket, fn -> Workspaces.upload(id, params["token"], params["path"], bytes) end)

      _ ->
        {:noreply, assign(socket, :notice, "Choose one file and wait for its upload to finish.")}
    end
  end

  def handle_event("collect", params, socket) do
    id = workspace_id(socket)
    socket = assign(socket, :download_path, params["path"])
    mutate(socket, fn -> Workspaces.collect(id, params["token"], params["path"]) end)
  end

  def handle_event("download-change", %{"path" => path}, socket),
    do: {:noreply, assign(socket, :download_path, path)}

  def handle_event("cancel", %{"id" => token}, socket),
    do: {:noreply, assign(socket, :confirming_cancel, token)}

  def handle_event("keep-command", _, socket),
    do: {:noreply, assign(socket, :confirming_cancel, nil)}

  def handle_event("confirm-cancel", %{"id" => token}, socket) do
    if socket.assigns.confirming_cancel == token do
      id = workspace_id(socket)
      mutate(assign(socket, :confirming_cancel, nil), fn -> Workspaces.cancel(id, token) end)
    else
      {:noreply, socket}
    end
  end

  def handle_event("logs", _, socket) do
    id = workspace_id(socket)
    {:noreply, start_async(socket, :logs, fn -> Workspaces.logs(id) end)}
  end

  def handle_event("open-terminal", _, %{assigns: %{error: error}} = socket) when error != nil,
    do: {:noreply, socket}

  def handle_event("open-terminal", _, %{assigns: %{terminal_status: status}} = socket)
      when status != :closed, do: {:noreply, socket}

  def handle_event("open-terminal", %{"token" => token}, socket) do
    case Workspaces.terminal(workspace_id(socket), token) do
      {:ok, execution} ->
        case DynamicSupervisor.start_child(
               Workspace.Terminals,
               {TerminalSession, {self(), execution}}
             ) do
          {:ok, pid} ->
            {:noreply, assign(socket, terminal: pid, terminal_status: :connecting)}

          {:error, {:already_started, _}} ->
            {:noreply, reconnect_terminal(socket)}

          _ ->
            {:noreply,
             assign(
               socket,
               :notice,
               "The shell could not be attached. Check its recorded outcome before starting another."
             )}
        end

      error ->
        {:noreply, assign(socket, :notice, error_message(error))}
    end
  end

  def handle_event("terminal-input", %{"bytes" => encoded}, socket)
      when byte_size(encoded) <= 24_000 do
    result =
      with {:ok, bytes} <- Base.decode64(encoded),
           do: terminal_call(socket, fn pid -> TerminalSession.input(pid, bytes) end)

    {:reply, %{ok: result == :ok}, socket}
  end

  def handle_event("terminal-resize", %{"cols" => cols, "rows" => rows}, socket) do
    terminal_call(socket, fn pid -> TerminalSession.resize(pid, cols, rows) end)
    {:noreply, socket}
  end

  def handle_event("terminal-ack", %{"seq" => seq}, socket) do
    if socket.assigns.terminal, do: TerminalSession.ack(socket.assigns.terminal, seq)
    {:noreply, socket}
  end

  def handle_event("resume-terminal", _, socket) do
    if socket.assigns.terminal do
      terminal_call(socket, &TerminalSession.reconnect_pid/1)
      {:noreply, socket}
    else
      {:noreply, reconnect_terminal(socket)}
    end
  end

  def handle_event("close-terminal", _, socket),
    do: {:noreply, assign(socket, :confirming_disconnect, true)}

  def handle_event("keep-terminal", _, socket),
    do: {:noreply, assign(socket, :confirming_disconnect, false)}

  def handle_event("confirm-disconnect", _, socket) do
    terminal_call(socket, &TerminalSession.close/1)

    {:noreply,
     assign(
       socket,
       :notice,
       "Closing the connection. An observed exit is needed to confirm the shell stopped."
     )}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp terminal_call(socket, fun) do
    if socket.assigns.terminal,
      do: Workspaces.safe(fn -> fun.(socket.assigns.terminal) end),
      else: {:error, :closed}
  end

  defp reconnect_terminal(%{assigns: %{terminal: nil, error: nil}} = socket) do
    case machine(socket.assigns.snapshot) do
      %{state: :running, active_execution: {_, _} = key} ->
        case Workspaces.safe(fn -> TerminalSession.reconnect(key) end) do
          {:ok, pid} -> assign(socket, terminal: pid, terminal_status: :connecting)
          _ -> socket
        end

      _ ->
        socket
    end
  end

  defp reconnect_terminal(socket), do: socket

  defp reconcile_terminal_notice(%{assigns: %{terminal_warning: true}} = socket) do
    if idle?(machine(socket.assigns.snapshot)) do
      socket
      |> assign(
        terminal_warning: false,
        notice: "Workspace available. The earlier terminal outcome remains in Activity."
      )
      |> push_event("terminal-recovered", %{})
    else
      socket
    end
  end

  defp reconcile_terminal_notice(socket), do: socket

  defp mutate(%{assigns: %{error: error}} = socket, _) when error != nil, do: {:noreply, socket}

  defp mutate(%{assigns: %{busy: true}} = socket, _), do: {:noreply, socket}

  defp mutate(socket, fun),
    do: {:noreply, socket |> assign(busy: true, notice: nil) |> start_async(:mutation, fun)}

  defp workspace_id(%{assigns: %{snapshot: %{home: %{id: id}}}}), do: id
  defp workspace_id(_), do: nil
  defp machine(%{machine: {:ok, record}}), do: record
  defp machine(_), do: nil
  defp state(nil), do: :none
  defp state(record), do: record.state

  defp terminal_connection_lost?(%{active_execution: {_, id}}, %{history: history}) do
    Enum.any?(history, fn
      %{id: ^id, execution: {:ok, %{last_error: %{operation: :terminal_consumer}}}} -> true
      _ -> false
    end)
  end

  defp terminal_connection_lost?(_, _), do: false

  defp ready?(record),
    do:
      record != nil and record.state == :running and record.active_execution == nil and
        record.operation == nil

  defp idle?(record),
    do:
      record != nil and record.active_execution == nil and record.operation == nil and
        record.state in [:created, :running, :stopped]

  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp error_message({:error, %{category: category}}), do: error_message({:error, category})

  defp error_message({:error, :admission_exhausted}),
    do:
      "This machine is busy or its capacity is reserved. Wait for the active operation; uncertain work needs operator recovery."

  defp error_message({:error, :identity_conflict}),
    do:
      "That request identity already belongs to different work. Keep the original record and use New run for an intentional new command."

  defp error_message({:error, :reserved_path}),
    do:
      "That path is reserved for file collection. Choose another filename. No transfer was submitted."

  defp error_message({:error, :workdir_policy}),
    do: "Working directory must be under /app/project or /home/dev. No command was submitted."

  defp error_message({:error, :file_policy}),
    do: "Choose a path under /app/project or /home/dev/.config and a file no larger than 16 MiB."

  defp error_message({:error, reason}) when is_atom(reason),
    do: "Request not completed: #{label(reason)}. Check the recorded state before retrying."

  defp error_message(_),
    do: "The outcome is uncertain. Inspect the recorded state before starting new work."

  defp announcement(nil, _), do: nil

  defp announcement(previous, current) do
    machine_state = state(machine(current))

    machine_change =
      if state(machine(previous)) != machine_state, do: "Workspace #{label(machine_state)}."

    outcome = Enum.find(current.history, &changed_outcome?(&1, previous.history))

    command_change =
      if outcome,
        do:
          "#{label(outcome.kind)} #{label(execution_state(outcome))}. #{result_label(outcome)}. Request #{outcome.id}."

    case Enum.reject([machine_change, command_change], &is_nil/1) do
      [] -> nil
      changes -> Enum.join(changes, " ")
    end
  end

  defp changed_outcome?(action, history) do
    current = execution_state(action)
    previous = Enum.find(history, &(&1.id == action.id))

    current in [:completed, :failed, :unknown, :cancelled, :launched] and
      (previous == nil or execution_state(previous) != current)
  end

  defp execution_state(%{
         kind: "download",
         execution: {:ok, %{collection: :complete, result: %SmolBox.Result{exit_code: code}}}
       })
       when code != 0, do: :failed

  defp execution_state(%{execution: {:ok, e}}), do: e.state

  defp execution_state(%{state: "submitted", kind: kind})
       when kind in ["start", "stop", "delete"], do: :accepted

  defp execution_state(action), do: action.state

  defp output(%{execution: {:ok, %{result: %SmolBox.Result{} = r}}}) do
    case r.stdout <> if(r.stderr == "", do: "", else: "\n" <> r.stderr) do
      "" -> nil
      bytes -> text(bytes)
    end
  end

  defp output(_), do: nil

  defp text(bytes),
    do:
      if(String.valid?(bytes),
        do: bytes,
        else: "Binary output (base64): " <> Base.encode64(bytes)
      )

  defp result_label(%{execution: {:ok, %{result: %SmolBox.LaunchResult{pid: pid}}}}),
    do: "Launch confirmed · PID #{pid} · not supervised"

  defp result_label(%{execution: {:ok, %{result: %{exit_code: code}}}}), do: "Exit #{code}"
  defp result_label(_), do: nil

  defp collected?(%{
         kind: "download",
         execution: {:ok, %{collection: :complete, result: %SmolBox.Result{exit_code: 0}}}
       }),
       do: true

  defp collected?(_), do: false

  defp active_terminal?(%{active_execution: {_, id}}, %{history: history}),
    do: Enum.any?(history, &(&1.id == id and &1.kind == "terminal"))

  defp active_terminal?(_, _), do: false

  defp pending?(%{execution: {:ok, e}}),
    do: not SmolBox.Execution.terminal?(e) and e.state != :unknown

  defp pending?(_), do: false

  def render(assigns) do
    assigns = assign(assigns, :machine, machine(assigns.snapshot))

    ~H"""
    <div class="app-shell">
      <header class="masthead">
        <a href="/" class="brand" aria-label="SmolBox workspace home">
          <svg viewBox="0 0 28 28" aria-hidden="true"><path d="M4 7h20v17H4zM4 7l5-4h10l5 4M10 13h8M10 18h5" /></svg>SmolBox<span>Workspace</span>
        </a>
        <span class="local-note">Local example <span class="version">v0.2.0</span></span>
      </header>
      <main id="main">
        <div class="page-heading">
          <div>
            <h1>A little room to build.</h1>
            <p>Run, explore, and come back. Your machine stays yours until you delete it.</p>
          </div>
          <a
            href="https://hexdocs.pm/smolbox/0.2.0/"
            target="_blank"
            rel="noopener noreferrer"
            class="text-link"
          >
            Read the docs
            <svg class="arrow-icon" viewBox="0 0 20 20" aria-hidden="true">
              <path d="M4 16 16 4M5 4h11v11" />
            </svg>
          </a>
        </div>
        <div id="workspace-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {@announcement}
        </div>
        <div id="connection-warning" class="connection-warning" role="status">
          <span class="phx-client-error">
            Connection lost. Your machine is retained. Reconnecting…
          </span>
          <span class="phx-server-error">The app is unavailable. Your machine is retained.</span>
        </div>
        <div :if={@notice} id="notice" class="notice" role="status">{@notice}</div>
        <section :if={@error} class="setup-panel" aria-labelledby="setup-title">
          <h2 id="setup-title">
            {if @snapshot, do: "Connection needs attention", else: "Let’s connect your workspace."}
          </h2>
          <p>
            {label(@error)}. Your worker and database must be available before this app can manage a workspace.
          </p>
          <ol>
            <li>Start PostgreSQL and your dedicated smolvm 1.17.0 worker.</li>
            <li>
              Set <code>DATABASE_URL</code>
              and run the example’s <code>mix workspace.setup</code>
              command with your approved image.
            </li>
            <li>Keep the generated private configuration and keys across app restarts.</li>
          </ol>
          <p>
            The setup command and recovery steps are in <code>examples/community_workspace/README.md</code>. No machine is created during setup.
          </p>
        </section>
        <section :if={@snapshot && !@snapshot.home} class="welcome" aria-labelledby="welcome-title">
          <div>
            <h2 id="welcome-title">Start with one persistent machine.</h2>
            <p>
              Your workspace includes a Python web service, a project directory, and room for commands, files, and a real terminal.
            </p>
            <button
              class="primary"
              phx-click="create"
              disabled={@busy || @error != nil}
              phx-disable-with="Recording…"
            >
              Create workspace
              <svg class="arrow-icon" viewBox="0 0 20 20" aria-hidden="true">
                <path d="M3 10h14m-5-5 5 5-5 5" />
              </svg>
            </button>
          </div>
          <ol class="walkthrough">
            <li>
              <strong>Make something</strong><span>Run a command, open a shell, or upload a file.</span>
            </li>
            <li>
              <strong>Leave and return</strong><span>Restart this app. The same machine and files remain.</span>
            </li>
            <li>
              <strong>Keep control</strong><span>Stop, start, or explicitly delete when you’re finished.</span>
            </li>
          </ol>
        </section>
        <section :if={@snapshot && @snapshot.home} class="workspace" aria-labelledby="workspace-title">
          <header class="workspace-header">
            <div>
              <h2 id="workspace-title">{@snapshot.home.label}</h2>
              <span class={"state state-#{state(@machine)}"} id="machine-state">
                {if @machine, do: label(@machine.state), else: "Awaiting durable evidence"}
              </span>
            </div>
            <div class="lifecycle">
              <button
                :if={@machine && @machine.state in [:created, :stopped]}
                class="primary compact"
                phx-click="start"
                disabled={@busy || @error != nil}
              >
                Start machine
              </button>
              <button
                :if={@machine && @machine.state == :running}
                phx-click="stop"
                disabled={@error != nil || @busy || !idle?(@machine)}
              >
                Stop machine
              </button>
              <button
                :if={@machine && @machine.state != :deleted}
                class="danger-text"
                phx-click="delete"
                disabled={@error != nil || @busy || !idle?(@machine)}
              >
                Delete
              </button>
            </div>
          </header>
          <div class="machine-facts">
            <span>
              <span class="fact-label">Identity</span><code id="machine-id">{@snapshot.home.id}</code>
            </span>
            <span><span class="fact-label">Retention</span>Until you delete it</span><span><span class="fact-label">Allocation</span>1 CPU · 256 MiB · 4 GiB disk</span>
          </div>
          <div :if={@confirming_delete} class="delete-confirm" role="alert">
            <div>
              <strong>Delete this machine and its guest files?</strong>
              <p>
                Execution history and collected downloads remain. Capacity is released after absence is verified.
              </p>
            </div>
            <button class="danger" phx-click="delete" disabled={@busy || @error != nil}>
              Confirm deletion
            </button>
            <button phx-click="keep">Keep workspace</button>
          </div>
          <div
            :if={@machine && @machine.state in [:unknown, :missing, :conflict]}
            class="recovery-note"
            role="alert"
          >
            <h3>Workspace needs recovery</h3>
            <p :if={terminal_connection_lost?(@machine, @snapshot)}>
              The terminal connection was lost before the shell’s exit was confirmed. The shell may
              still be running, so new commands, terminals, and machine changes are blocked.
            </p>
            <p :if={!terminal_connection_lost?(@machine, @snapshot)}>
              The app cannot confirm this machine’s state or the outcome of its last operation.
              New work is blocked until an operator checks what happened.
            </p>
            <p>
              The app has not deleted your machine. Ask the person running this app to follow the
              operator recovery procedure in the example’s README. Recovery must stop any uncertain
              work before this workspace can be used again; unknown commands are never replayed.
            </p>
          </div>
          <div :if={@machine && @machine.state == :deleted} class="deleted-note">
            <h3>Machine deleted. History retained.</h3>
            <p>
              Verified absence: {if @machine.absence_at_ms, do: "yes", else: "awaiting evidence"}. Reserved capacity: {if @machine.reservation ==
                                                                                                                            nil,
                                                                                                                          do:
                                                                                                                            "released",
                                                                                                                          else:
                                                                                                                            "retained"}. This identity will never create a replacement machine.
            </p>
          </div>
          <nav class="workspace-nav" aria-label="Workspace sections">
            <a href="#commands">Commands</a><a href="#files">Files</a>
            <a href="#shell">Terminal</a><a href="#activity">Activity</a>
          </nav>
          <div class="work-area">
            <div class="command-column">
              <section id="commands" aria-labelledby="command-title" tabindex="-1">
                <div class="section-heading">
                  <h3 id="command-title">Run a command</h3>
                  <span class="subtle">One active command at a time</span>
                </div>
                <form
                  id="command-form"
                  phx-hook="Intent"
                  phx-submit="command"
                  phx-change="change-command"
                >
                  <input type="hidden" name="token" value={@token} />
                  <label for="command" class="sr-only">Shell command</label><textarea
                    id="command"
                    name="command"
                    rows="3"
                    maxlength="16384"
                    spellcheck="false"
                    required
                    disabled={@error != nil || !ready?(@machine) || @busy}
                  >{@command}</textarea>
                  <div class="command-options">
                    <label>Working directory<input name="workdir" value={@cwd} required /></label><label>Mode<select name="mode"><option
                        value="foreground"
                        selected={@mode == "foreground"}
                      >Foreground</option><option value="background" selected={@mode == "background"}>Background</option></select></label><label>Timeout, seconds<input
                      name="timeout"
                      type="number"
                      min="1"
                      max="600"
                      value={@timeout}
                      readonly={@mode == "background"}
                    /></label>
                  </div>
                  <p :if={@mode == "background"} class="field-note">
                    Returns launch evidence and a PID. It does not supervise the process or report its eventual exit.
                  </p>
                  <div class="command-actions">
                    <button
                      class="primary"
                      type="submit"
                      disabled={@error != nil || !ready?(@machine) || @busy}
                      phx-disable-with="Recording…"
                    >
                      Run command
                      <svg class="arrow-icon" viewBox="0 0 20 20" aria-hidden="true">
                        <path d="M3 10h14m-5-5 5 5-5 5" />
                      </svg>
                    </button>
                    <button type="button" phx-click="new-command" disabled={@busy || @error != nil}>
                      New run
                    </button>
                    <span class="subtle">Output appears when the command completes.</span>
                  </div>
                </form>
                <details class="sample-list">
                  <summary>Try a sample command</summary>
                  <button
                    :for={{{title, _, _, _}, index} <- Enum.with_index(Workspace.Sample.commands())}
                    phx-click="sample"
                    phx-value-index={index}
                  >
                    {title}
                  </button>
                  <p>“Run beyond five minutes” takes 305 seconds. It is optional.</p>
                </details>
              </section>
              <section id="activity" class="history" aria-labelledby="history-title" tabindex="-1">
                <div class="section-heading">
                  <h3 id="history-title">Activity</h3>
                  <span class="subtle">Latest 50 durable requests</span>
                </div>
                <p :if={@snapshot.history == []} class="empty-history">
                  Your first command starts the story. Results stay here when you reconnect.
                </p>
                <.activity
                  :for={action <- Enum.take(@snapshot.history, 2)}
                  action={action}
                  confirming_cancel={@confirming_cancel}
                />
                <details :if={length(@snapshot.history) > 2} class="earlier-activity">
                  <summary>Earlier requests ({length(@snapshot.history) - 2})</summary>
                  <.activity
                    :for={action <- Enum.drop(@snapshot.history, 2)}
                    action={action}
                    confirming_cancel={@confirming_cancel}
                  />
                </details>
              </section>
            </div>
            <aside class="workspace-tools" aria-label="Workspace tools">
              <section class="service-panel">
                <h3>Mapped service</h3>
                <p>
                  The startup workload serves <code>/app/project</code>. Edit <code>index.html</code>, then refresh its page.
                </p>
                <a
                  class={"service-link #{if !ready?(@machine), do: "muted", else: ""}"}
                  href={@snapshot.preview_url}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  Open service
                  <svg class="arrow-icon" viewBox="0 0 20 20" aria-hidden="true">
                    <path d="M4 16 16 4M5 4h11v11" />
                  </svg>
                </a>
                <p class="field-note">
                  TCP {@snapshot.service_port} → 8000 · Availability depends on the workload. A running VM alone is not proof of readiness.
                </p>
              </section>
              <section id="files" class="files-panel" tabindex="-1">
                <h3>Move a file</h3>
                <p>Up to 16 MiB per file. Transfers use the same managed command slot.</p>
                <form id="upload-form" phx-hook="Intent" phx-submit="upload" phx-change="file-change">
                  <input type="hidden" name="token" value={@token} />
                  <label>
                    Guest destination<input name="path" value={@upload_path} required />
                  </label>
                  <label for={@uploads.file.ref}>Local file</label>
                  <.live_file_input
                    upload={@uploads.file}
                    disabled={@error != nil || !ready?(@machine) || @busy}
                  />
                  <p :for={error <- upload_errors(@uploads.file)} class="field-error">
                    {label(error)}
                  </p>
                  <div :for={entry <- @uploads.file.entries}>
                    <span>{entry.client_name} · {entry.progress}%</span>
                    <p :for={error <- upload_errors(@uploads.file, entry)} class="field-error">
                      {label(error)}
                    </p>
                  </div>
                  <button type="submit" disabled={@error != nil || !ready?(@machine) || @busy}>
                    Upload to machine
                  </button>
                </form>
                <form
                  id="download-form"
                  phx-hook="Intent"
                  phx-submit="collect"
                  phx-change="download-change"
                >
                  <input type="hidden" name="token" value={@token} />
                  <label>
                    Guest file to download<input name="path" value={@download_path} required />
                  </label>
                  <button type="submit" disabled={@error != nil || !ready?(@machine) || @busy}>
                    Collect file
                  </button>
                </form>
                <p class="field-note">
                  Try <code>/app/project/starts.txt</code>, created when the machine starts.
                  Collect an existing file; create <code>artifact.bin</code>
                  with the sample command first.
                </p>
                <p class="field-note">
                  Approved roots: <code>/app/project</code>
                  and <code>/home/dev/.config</code>. Collected downloads appear in Activity.
                </p>
              </section>
            </aside>
          </div>
          <section id="shell" class="terminal-section" aria-labelledby="terminal-title" tabindex="-1">
            <div class="section-heading">
              <div>
                <h3 id="terminal-title">Interactive terminal</h3>
                <p>
                  Open a shell on your machine. Use <code>cd /app/project</code>
                  to enter your project directory.
                </p>
              </div>
              <form id="terminal-form" phx-hook="Intent" phx-submit="open-terminal">
                <input type="hidden" name="token" value={@token} />
                <button
                  :if={@terminal_status == :closed}
                  type="submit"
                  disabled={@error != nil || !ready?(@machine) || @busy}
                >
                  Open terminal
                </button>
                <button
                  :if={@terminal_status != :closed}
                  type="button"
                  phx-click="close-terminal"
                >
                  Disconnect…
                </button>
              </form>
            </div>
            <div :if={@confirming_disconnect} class="disconnect-confirm" role="alert">
              <p>Disconnecting does not stop the shell and may require operator recovery.
                To finish normally, type <code>exit</code> in the terminal.</p>
              <button type="button" phx-click="keep-terminal">Keep terminal</button>
              <button type="button" phx-click="confirm-disconnect">Disconnect anyway</button>
            </div>
            <p
              :if={
                @terminal_status == :closed && @machine && @machine.state == :running &&
                  @machine.active_execution != nil
              }
              class="field-note"
            >
              <span :if={active_terminal?(@machine, @snapshot)}>
                The terminal is open in another tab. Use it there, or close that tab and return here
                within 30 seconds to reconnect while this app stays running.
              </span>
              <span :if={!active_terminal?(@machine, @snapshot)}>
                A command or file transfer is using this machine. Wait for its outcome in Activity.
              </span>
            </p>
            <p
              :if={@terminal_status == :closed && @machine && @machine.state == :unknown}
              class="field-note"
            >
              The previous operation has an unknown outcome. Reconnection is no longer available;
              follow Console diagnostics &amp; recovery before opening another terminal.
            </p>
            <div
              id="terminal"
              phx-hook="Terminal"
              phx-update="ignore"
              class="terminal"
              aria-label="Interactive guest terminal"
            >
              <div class="terminal-placeholder">
                Your terminal will appear here.
              </div>
            </div>
            <p :if={!@machine || @machine.state != :unknown} class="field-note">
              Before refreshing or leaving, type <code>exit</code> and wait for “Terminal exited”.
              A page refresh or brief connection loss can reconnect to the same shell within 30 seconds
              while this app stays running. Longer interruptions or an app restart may need operator
              recovery. Previous terminal output is not saved. Escape moves focus out of the terminal.
            </p>
          </section>
          <details class="diagnostics">
            <summary>Console diagnostics &amp; recovery</summary>
            <p>
              Console diagnostics are worker/VM output. Upstream does not capture the startup workload’s application stdout/stderr.
            </p>
            <button phx-click="logs" disabled={@busy || @error != nil}>Read console snapshot</button><pre
              :if={@logs}
              class="output"
            >{@logs}</pre>
            <p>
              Keep PostgreSQL, the private <code>.workspace</code>
              directory and its keys. Before a planned app restart, finish foreground work and exit the terminal. Background work remains on the retained machine; stop/start does not replay its launch.
            </p>
            <p>
              For unknown work or a missing machine, use the README’s operator recovery procedure. Do not delete records to retry.
            </p>
          </details>
        </section>
        <div :if={!@snapshot && !@error} class="loading" role="status">
          Reading your durable workspace…
        </div>
      </main>
      <footer>
        <span>Built with SmolBox. Kept by you.</span><span>One worker. Explicit ownership. No automatic deletion.</span>
      </footer>
    </div>
    """
  end

  defp activity(assigns) do
    ~H"""
    <article
      class="activity"
      id={"action-#{@action.id}"}
    >
      <div class="activity-title">
        <strong>{label(@action.kind)}</strong><span class="state">{label(execution_state(@action))}</span><span class="result-label">{result_label(@action)}</span><button
          :if={pending?(@action)}
          class="text-button"
          phx-click="cancel"
          phx-value-id={@action.id}
        >Cancel command…</button>
      </div>
      <div
        :if={@confirming_cancel == @action.id && pending?(@action)}
        class="disconnect-confirm"
        role="alert"
      >
        <p>Cancelling after dispatch stops observation, not necessarily the guest process.
          The workspace may require operator recovery before you can run more work.</p>
        <button type="button" phx-click="keep-command">Keep waiting</button>
        <button type="button" phx-click="confirm-cancel" phx-value-id={@action.id}>
          Cancel anyway
        </button>
      </div>
      <code :if={@action.payload["command"]} class="command-text">
        {@action.payload["command"]}
      </code>
      <code :if={@action.payload["path"]} class="command-text">
        {@action.payload["path"]}
      </code>
      <pre :if={output(@action)} class="output">{output(@action)}</pre>
      <p
        :if={@action.state == "prepared" && execution_state(@action) == "prepared"}
        class="field-note"
      >
        Acceptance is unresolved. Inspect durable state before making a new request; this action is never automatically replayed.
      </p>
      <p :if={@action.error} class="field-note">
        {label(@action.error)} — inspect the outcome before retrying.
      </p>
      <p :if={execution_state(@action) == :accepted} class="field-note">
        Request accepted; completion has not been recorded. The current machine state is shown above.
      </p>
      <a :if={collected?(@action)} class="text-link" href={"/downloads/#{@action.id}"} download>
        Download collected file
      </a>
      <details class="receipt">
        <summary>Request identity</summary>
        <code>{@action.id}</code>
      </details>
    </article>
    """
  end
end
