defmodule SmolBox.Runtime.MachineSession do
  @moduledoc false
  alias SmolBox.ManagedMachine
  alias SmolBox.Runtime.Session

  def store(config, operation, arguments),
    do: Session.store(config, :machine, [operation, arguments])

  def claim(config, key),
    do: store(config, :claim, [key, config.owner, config.clock.now(), config.lease_ms])

  def write(config, record, changes),
    do:
      store(config, :write, [
        ManagedMachine.key(record),
        Session.guard(record),
        changes,
        config.clock.now()
      ])

  def worker(config, record) do
    case Enum.find(config.workers, &(&1.client.worker.id == record.worker_id)) do
      nil -> Session.error(:unsupported_capability, :worker)
      worker -> {:ok, worker}
    end
  end

  def io(config, record, function) do
    deadline =
      record.operation_deadline_ms || config.clock.now() + record.spec.profile.preparation_ms

    if deadline <= config.clock.now(),
      do: Session.error(:expired, :runtime),
      else: start_io(config, record, function, deadline)
  end

  defp start_io(config, record, function, deadline) do
    task = Task.async(fn -> Session.safe(function) end)

    try do
      await_io(config, record, task, deadline)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp await_io(config, record, task, deadline) do
    budget = deadline - config.clock.now()

    if budget <= 0 do
      Session.error(:expired, :runtime)
    else
      case Task.yield(task, min(budget, config.poll_ms)) do
        {:ok, result} ->
          result

        nil ->
          renew_io(config, record, task, deadline)

        _lost ->
          Session.error(:unknown, :runtime)
      end
    end
  end

  defp renew_io(config, record, task, deadline) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         do: await_io(config, current, task, deadline)
  end
end
