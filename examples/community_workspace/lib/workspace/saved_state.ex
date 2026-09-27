defmodule Workspace.SavedState do
  @moduledoc "A bounded saved state walkthrough using durable public SmolBox APIs."
  alias SmolBox.{
    Branches,
    BranchSpec,
    CheckpointCaptureSpec,
    Checkpoints,
    Command,
    ExecutionSpec,
    Machines,
    ManagedMachineSpec
  }

  alias SmolBox.DurableHost.Store
  alias Workspace.{Connection, Settings}

  @capture "prepared-v1"
  @commands %{
    "prepare" =>
      "mkdir -p /workspace; printf 'Original recipe: basil and lemon\\n' > /workspace/recipe.txt; printf 'Prepared in memory\\n' > /dev/shm/workspace-note; cat /workspace/recipe.txt /dev/shm/workspace-note",
    "change" =>
      "printf 'Branch recipe: ginger and lime\\n' > /workspace/recipe.txt; printf 'Changed in branch memory\\n' > /dev/shm/workspace-note; cat /workspace/recipe.txt /dev/shm/workspace-note",
    "read-original" => "cat /workspace/recipe.txt /dev/shm/workspace-note",
    "read-branch" => "cat /workspace/recipe.txt /dev/shm/workspace-note"
  }
  @confirmations ~w(capture branch confirm-capture delete-child retire-child delete-source release-backing release-capture)

  def snapshot(%{saved_state: nil}), do: {:ok, nil}

  def snapshot(c) do
    safe(fn ->
      source = read(Machines.inspect(Settings.runtime(), handle(c, :source)))
      child = read(Machines.inspect(Settings.runtime(), handle(c, :child)))

      commands =
        Map.new(@commands, fn {key, _} ->
          {key, read(SmolBox.fetch(Settings.runtime(), Settings.scope(), command_id(c, key)))}
        end)

      {:ok,
       %{
         source: source,
         child: child,
         commands: commands,
         capture: if(source, do: source.captures[@capture]),
         source_id: elem(handle(c, :source), 1),
         child_id: elem(handle(c, :child), 1),
         usage: Store.usage(c.store, "workspace-worker")
       }}
    end)
  end

  def act(action, confirmed \\ false) do
    safe(fn ->
      with {:ok, c} <- Connection.context(),
           true <- c.saved_state != nil,
           {:ok, snapshot} <- snapshot(c),
           true <- allowed?(snapshot, action),
           true <- action not in @confirmations or confirmed == true do
        perform(action, c, snapshot)
      else
        false -> {:error, :saved_state_action_not_allowed}
        error -> error
      end
    end)
  end

  def allowed?(s, "create"), do: s.source == nil
  def allowed?(s, "start"), do: idle?(s.source) and s.source.state == :created
  def allowed?(s, "prepare"), do: running?(s.source) and s.commands["prepare"] == nil

  def allowed?(s, "capture"),
    do:
      running?(s.source) and success?(s.commands["prepare"]) and s.capture == nil and
        s.child == nil

  def allowed?(s, "confirm-capture"), do: s.capture != nil and s.capture.state == :captured

  def allowed?(s, "branch"),
    do:
      running?(s.source) and s.capture != nil and s.capture.state == :completed and s.child == nil

  def allowed?(s, "change"), do: running?(s.child) and s.commands["change"] == nil

  def allowed?(s, "compare"),
    do:
      running?(s.source) and running?(s.child) and success?(s.commands["change"]) and
        (s.commands["read-original"] == nil or s.commands["read-branch"] == nil)

  def allowed?(s, "delete-child"), do: idle?(s.child) and s.child.state != :deleted

  def allowed?(s, "retire-child"),
    do:
      s.child != nil and s.child.state == :deleted and s.child.branch.state in [:ready, :released]

  def allowed?(s, "delete-source"),
    do:
      idle?(s.source) and s.source.state != :deleted and
        (s.child == nil or s.child.branch.state in [:retired, :closed])

  def allowed?(s, "release-backing"),
    do:
      s.source != nil and s.source.state == :deleted and s.child != nil and
        s.child.branch.state == :retired

  def allowed?(s, "release-capture"),
    do: s.capture != nil and s.capture.state == :completed and s.capture.released_at_ms == nil

  def allowed?(_, _), do: false

  def success?(%{state: :completed, result: %{exit_code: 0}}), do: true
  def success?(_), do: false

  def output(%{result: %SmolBox.Result{stdout: out}}), do: out
  def output(_), do: nil

  defp idle?(nil), do: false

  defp idle?(m),
    do:
      m.state in [:created, :running, :stopped] and
        Enum.all?(
          [m.operation, m.active_execution, m.active_capture, m.active_branch, m.active_export],
          &is_nil/1
        )

  defp running?(m), do: idle?(m) and m.state == :running

  defp perform("create", c, _) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: Settings.scope(),
        id: elem(handle(c, :source), 1),
        artifact: SmolBox.Checkpoint.artifact(c.saved_state.seed),
        profile: c.saved_state.profile,
        checkpointable: true
      )

    Machines.create(Settings.runtime(), spec)
  end

  defp perform("start", c, s),
    do: Machines.start(Settings.runtime(), handle(c, :source), s.source.version)

  defp perform("prepare", c, s), do: submit(c, s.source, "prepare")
  defp perform("change", c, s), do: submit(c, s.child, "change")

  defp perform("compare", c, s) do
    with {:ok, _} <- submit(c, s.source, "read-original"),
         {:ok, _} <- submit(c, s.child, "read-branch"),
         do: {:ok, :comparison_submitted}
  end

  defp perform("capture", c, _) do
    {:ok, spec} =
      CheckpointCaptureSpec.new(id: @capture, policy: c.saved_state.capture_policy, idle: true)

    Checkpoints.capture(Settings.runtime(), handle(c, :source), spec)
  end

  defp perform("confirm-capture", c, s),
    do:
      Checkpoints.resolve(Settings.runtime(), capture_handle(c), s.source.version, quiesced: true)

  defp perform("branch", c, _) do
    {:ok, spec} =
      BranchSpec.new(
        id: elem(handle(c, :child), 1),
        policy: c.saved_state.branch_policy,
        idle: true
      )

    Branches.create(Settings.runtime(), handle(c, :source), spec)
  end

  defp perform("delete-child", c, s),
    do: Machines.delete(Settings.runtime(), handle(c, :child), s.child.version)

  defp perform("retire-child", c, _),
    do: Branches.retire(Settings.runtime(), handle(c, :child), quiesced: true)

  defp perform("delete-source", c, s),
    do: Machines.delete(Settings.runtime(), handle(c, :source), s.source.version)

  defp perform("release-backing", c, _),
    do: Branches.release_storage(Settings.runtime(), handle(c, :child), backing_removed: true)

  defp perform("release-capture", c, _),
    do: Checkpoints.release(Settings.runtime(), capture_handle(c), artifacts_removed: true)

  defp submit(c, machine, key) do
    {:ok, command} = Command.new(["/bin/sh", "-lc", @commands[key]], timeout_secs: 30)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: Settings.scope(),
        id: command_id(c, key),
        artifact: machine.spec.artifact,
        profile: machine.spec.profile,
        command: command,
        retention_ms: 60_000
      )

    Machines.submit(Settings.runtime(), {machine.scope, machine.id}, spec)
  end

  def handle(c, :source), do: {Settings.scope(), c.settings["workspace_id"] <> "-saved"}
  def handle(c, :child), do: {Settings.scope(), c.settings["workspace_id"] <> "-branch"}
  defp command_id(c, key), do: c.settings["workspace_id"] <> "-saved-" <> key
  defp capture_handle(c), do: {Settings.scope(), elem(handle(c, :source), 1), @capture}
  defp read({:ok, value}), do: value
  defp read({:error, %{category: :not_found}}), do: nil
  defp read(error), do: throw({:read_failed, error})

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
    {:read_failed, error} -> error
  end
end
