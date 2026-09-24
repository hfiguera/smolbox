defmodule Workspace.Workspaces do
  @moduledoc "Application actions over public SmolBox APIs, with durable browser identities."
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Command, ExecutionSpec, Machines, ManagedMachineSpec, PortMapping, Workload}
  alias SmolBox.DurableHost.Store
  alias SmolBox.Terminal.Spec
  alias Workspace.{Connection, Ledger, Settings}

  def snapshot do
    safe(fn ->
      with {:ok, c} <- Connection.context() do
        home = Ledger.home(c)
        machine = inspect_home(home)
        history = history(c, home)

        {:ok,
         %{
           home: home,
           machine: machine,
           history: history,
           preview_url: c.settings["preview_url"],
           service_port: c.settings["service_port"],
           connection: Connection.status(),
           usage: Store.usage(c.store, "workspace-worker")
         }}
      end
    end)
  end

  defp inspect_home(nil), do: nil
  defp inspect_home(home), do: Machines.inspect(Settings.runtime(), handle(home.id))

  defp history(_, nil), do: []
  defp history(c, home), do: Enum.map(Ledger.actions(c, home.id), &decorate/1)

  def create do
    safe(fn ->
      with {:ok, c} <- Connection.context(),
           id = c.settings["workspace_id"],
           {:ok, mapping} <- PortMapping.new(host: c.settings["service_port"], guest: 8000),
           {:ok, workload} <-
             Workload.new(
               entrypoint: ["python3"],
               cmd: ["-c", Workspace.Sample.startup()],
               env: [{"WORKSPACE_NAME", "My workspace"}],
               workdir: "/"
             ),
           {:ok, spec} <-
             ManagedMachineSpec.new(
               scope: Settings.scope(),
               id: id,
               artifact: c.artifact,
               profile: c.profile,
               ports: [mapping],
               workload: workload
             ),
           :ok <- Ledger.put_home(c, id, "My workspace"),
           {:ok, _} <- Machines.create(Settings.runtime(), spec),
           do: {:ok, id}
    end)
  end

  def lifecycle(action, id, token) when action in [:start, :stop, :delete] do
    safe(fn ->
      with :ok <- token_valid(token),
           {:ok, c} <- Connection.context(),
           :ok <- authorize(c, id),
           {:ok, machine} <- Machines.inspect(Settings.runtime(), handle(id)),
           {:ok, state} <-
             Ledger.reserve(c, token, id, Atom.to_string(action), %{
               "operation" => Atom.to_string(action)
             }) do
        dispatch_lifecycle(state, c, id, token, action, machine)
      end
    end)
  end

  defp dispatch_lifecycle(:inserted, c, id, token, action, machine),
    do: lifecycle_request(c, id, token, action, machine, 3)

  defp dispatch_lifecycle(_, _, _, _, _, _), do: {:ok, :already_recorded}

  defp lifecycle_request(c, id, token, action, machine, remaining) do
    case apply(Machines, action, [Settings.runtime(), handle(id), machine.version]) do
      {:error, %{category: :stale_version, evidence: :not_dispatched}} when remaining > 0 ->
        with {:ok, fresh} <- Machines.inspect(Settings.runtime(), handle(id)),
             true <- fresh.state == machine.state and fresh.active_execution == nil do
          lifecycle_request(c, id, token, action, fresh, remaining - 1)
        else
          _ -> record(c, token, {:error, :state_changed})
        end

      result ->
        record(c, token, result)
    end
  end

  def command(id, token, params) do
    safe(fn ->
      with :ok <- token_valid(token),
           {:ok, c} <- Connection.context(),
           :ok <- authorize(c, id),
           {:ok, machine} <- Machines.inspect(Settings.runtime(), handle(id)),
           {:ok, command} <- build_command(params),
           {:ok, _} <-
             Ledger.reserve(
               c,
               token,
               id,
               "command",
               Map.take(params, ["command", "workdir", "mode", "timeout"])
             ),
           {:ok, spec} <- execution(machine, token, command),
           do: record(c, token, Machines.submit(Settings.runtime(), handle(id), spec))
    end)
  end

  def upload(id, token, path, bytes) do
    safe(fn ->
      with :ok <- token_valid(token),
           true <- is_binary(bytes) and byte_size(bytes) <= Settings.max_file_bytes(),
           {:ok, c} <- Connection.context(),
           :ok <- authorize(c, id),
           {:ok, machine} <- Machines.inspect(Settings.runtime(), handle(id)),
           true <- SmolBox.GuestPaths.allowed?(machine.spec.profile.guest_paths, :upload, path),
           digest = SmolBox.Files.sha256(bytes),
           {:ok, _} <-
             Ledger.reserve(c, token, id, "upload", %{
               "path" => path,
               "size" => byte_size(bytes),
               "sha256" => digest
             }),
           :ok <- Directory.seed(c.objects, Settings.scope(), token, bytes),
           {:ok, command} <- noop(),
           input = %{
             "source" => token,
             "path" => path,
             "size" => byte_size(bytes),
             "sha256" => digest,
             "mode" => "runtime_default"
           },
           {:ok, spec} <- execution(machine, token, command, inputs: [input]) do
        record(c, token, Machines.submit(Settings.runtime(), handle(id), spec))
      else
        false -> {:error, :file_policy}
        error -> error
      end
    end)
  end

  def collect(id, token, path) do
    safe(fn ->
      with :ok <- token_valid(token),
           {:ok, c} <- Connection.context(),
           :ok <- authorize(c, id),
           {:ok, machine} <- Machines.inspect(Settings.runtime(), handle(id)),
           true <- SmolBox.GuestPaths.allowed?(machine.spec.profile.guest_paths, :download, path),
           {:ok, _} <- Ledger.reserve(c, token, id, "download", %{"path" => path}),
           {:ok, command} <- noop(),
           output = %{
             "destination" => "download",
             "path" => path,
             "max_bytes" => Settings.max_file_bytes()
           },
           {:ok, spec} <- execution(machine, token, command, outputs: [output]) do
        record(c, token, Machines.submit(Settings.runtime(), handle(id), spec))
      else
        false -> {:error, :file_policy}
        error -> error
      end
    end)
  end

  def download(token) do
    safe(fn ->
      with :ok <- token_valid(token),
           {:ok, c} <- Connection.context(),
           {:ok, %{kind: "download", payload: payload}} <- Ledger.action(c, token),
           {:ok, %{collection: :complete}} <-
             SmolBox.fetch(Settings.runtime(), Settings.scope(), token),
           {:ok, bytes} <-
             Directory.read_output(
               c.objects,
               handle(token),
               "download",
               Settings.max_file_bytes()
             ),
           do: {:ok, Path.basename(payload["path"]), bytes}
    end)
  end

  def terminal(id, token) do
    safe(fn ->
      with :ok <- token_valid(token),
           {:ok, c} <- Connection.context(),
           :ok <- authorize(c, id),
           {:ok, machine} <- Machines.inspect(Settings.runtime(), handle(id)),
           {:ok, _} <- Ledger.reserve(c, token, id, "terminal", %{"program" => "/bin/sh"}),
           {:ok, command} <-
             Spec.new(
               program: "/bin/sh",
               session_ms: 600_000,
               idle_ms: 300_000,
               attach_ms: 10_000,
               max_buffer_bytes: 65_536
             ),
           {:ok, spec} <- execution(machine, token, command),
           do: record(c, token, SmolBox.Terminal.open(Settings.runtime(), handle(id), spec))
    end)
  end

  def cancel(id, token) do
    safe(fn ->
      with {:ok, c} <- Connection.context(),
           :ok <- authorize(c, id),
           {:ok, action} <- Ledger.action(c, token),
           true <- action.machine_id == id,
           do: SmolBox.cancel(Settings.runtime(), Settings.scope(), token)
    end)
  end

  def logs(id) do
    safe(fn ->
      with {:ok, c} <- Connection.context(),
           :ok <- authorize(c, id),
           do:
             Machines.logs(Settings.runtime(), handle(id),
               tail: 50,
               max_output_bytes: 16_384,
               timeout_ms: 5000
             )
    end)
  end

  def handle(id), do: {Settings.scope(), id}

  def safe(function) do
    function.()
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp build_command(%{"command" => text, "workdir" => cwd, "mode" => mode, "timeout" => timeout}) do
    with true <- is_binary(text) and byte_size(text) in 1..16_384,
         true <- mode in ["foreground", "background"],
         {seconds, ""} <- Integer.parse(to_string(timeout)),
         true <- seconds in 1..600 do
      options =
        [workdir: cwd] ++
          if(mode == "background", do: [background: true], else: [timeout_secs: seconds])

      Command.new(["/bin/sh", "-lc", text], options)
    else
      _ -> {:error, :invalid_command}
    end
  end

  defp build_command(_), do: {:error, :invalid_command}
  defp noop, do: Command.new(["/bin/true"], workdir: "/app/project", timeout_secs: 5)

  defp execution(machine, id, command, options \\ []) do
    ExecutionSpec.new(
      [
        scope: machine.scope,
        id: id,
        artifact: machine.spec.artifact,
        profile: machine.spec.profile,
        command: command,
        retention_ms: 60_000
      ] ++ options
    )
  end

  defp authorize(c, id) do
    case Ledger.home(c) do
      %{id: ^id} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp token_valid(token) do
    case Ecto.UUID.cast(token) do
      {:ok, ^token} -> :ok
      _ -> {:error, :invalid_identity}
    end
  end

  defp record(c, token, {:ok, _} = result) do
    Ledger.mark(c, token, "submitted")
    result
  end

  defp record(c, token, {:error, %{category: category, evidence: evidence}} = result) do
    Ledger.mark(
      c,
      token,
      if(evidence == :not_dispatched, do: "not_dispatched", else: "unknown"),
      Atom.to_string(category)
    )

    result
  end

  defp record(c, token, {:error, error} = result) when is_atom(error) do
    Ledger.mark(c, token, "unknown", Atom.to_string(error))
    result
  end

  defp decorate(action) do
    execution =
      if action.kind in ["command", "upload", "download", "terminal"],
        do: SmolBox.fetch(Settings.runtime(), Settings.scope(), action.id),
        else: nil

    Map.put(action, :execution, execution)
  end
end
