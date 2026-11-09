defmodule SmolBox.Runtime.MachineSession do
  alias SmolBox.Runtime.Target
  @moduledoc false
  alias SmolBox.ManagedMachine
  alias SmolBox.Runtime.{Deadline, Session}

  def store(config, operation, arguments),
    do: Session.store(config, :machine, [operation, arguments])

  def claim(config, key),
    do: store(config, :claim, [key, config.owner, config.clock.now(), config.lease_ms])

  def advance_unknown_branch(config, parent, child, change),
    do:
      store(config, :branch_advance, [
        ManagedMachine.key(parent),
        Session.guard(parent),
        child.id,
        :unknown,
        change,
        config.clock.now()
      ])

  def commit_branch_result(config, child, result, deadline) do
    with {:ok, _} <- Deadline.remaining(deadline, :branch),
         {:ok, parent} <- claim(config, child.branch.source),
         {:ok, _} <- Deadline.remaining(deadline, :branch) do
      store(config, :branch_resolve, [
        child.branch.source,
        Session.guard(parent),
        child.id,
        result.source,
        result,
        config.clock.now()
      ])
    end
  end

  def write(config, record, changes),
    do:
      store(config, :write, [
        ManagedMachine.key(record),
        Session.guard(record),
        changes,
        config.clock.now()
      ])

  def worker(config, record) do
    case Enum.find(config.workers, &(Target.id(&1) == record.worker_id)) do
      nil -> Session.error(:unsupported_capability, :worker)
      worker -> {:ok, worker}
    end
  end

  def io(config, record, function) do
    anchor = {config.clock.now(), config.clock.monotonic()}

    deadline =
      record.operation_deadline_ms || elem(anchor, 0) + record.spec.profile.preparation_ms

    if Deadline.remaining(config.clock, deadline, anchor) <= 0,
      do: Session.error(:expired, :runtime),
      else: start_io(config, record, function, deadline, anchor)
  end

  defp start_io(config, record, function, deadline, anchor) do
    task = Task.async(fn -> Session.safe(function) end)

    try do
      await_io(config, record, task, deadline, anchor)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp await_io(config, record, task, deadline, anchor) do
    budget = Deadline.remaining(config.clock, deadline, anchor)

    if budget <= 0 do
      Session.error(:expired, :runtime)
    else
      case Task.yield(task, min(budget, config.poll_ms)) do
        {:ok, result} ->
          result

        nil ->
          renew_io(config, record, task, deadline, anchor)

        _lost ->
          Session.error(:unknown, :runtime)
      end
    end
  end

  defp renew_io(config, record, task, deadline, anchor) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         do: await_io(config, current, task, deadline, anchor)
  end
end
