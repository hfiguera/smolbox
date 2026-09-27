defmodule SmolBox.DurableHost.CaptureStore do
  @moduledoc false
  if Code.ensure_loaded?(SmolBox.Store.CaptureOps) do
    alias SmolBox.DurableHost.Database
    alias SmolBox.Store.CaptureOps
    def capabilities, do: %{managed_checkpoints: 1}

    def run(context, :capture_accept, [key, spec, fingerprint, capacity, now]) do
      with {:ok, m} <- Database.read(context, key, :machine),
           {:ok, usage} <- Database.usage(context, m.worker_id),
           do: CaptureOps.accept(m, spec, fingerprint, capacity, usage, now)
    end

    def run(context, :capture_cancel, [key, id, now]) do
      with {:ok, m} <- Database.read(context, key, :machine), do: CaptureOps.cancel(m, id, now)
    end

    def run(context, :capture_advance, [key, guard, id, expected, changes, now]) do
      with {:ok, m} <- Database.guarded_machine(context, key, guard, now),
           do: CaptureOps.advance(m, id, expected, changes, now)
    end

    def run(context, :capture_resolve, [key, guard, id, observed, now]) do
      with {:ok, m} <- Database.guarded_machine(context, key, guard, now),
           do: CaptureOps.resolve(m, id, observed, now)
    end

    def run(context, :capture_release, [key, guard, id, now]) do
      with {:ok, m} <- Database.guarded_machine(context, key, guard, now),
           do: CaptureOps.release(m, id, now)
    end
  else
    def capabilities, do: %{}

    def run(_, _, _),
      do: {:error, %SmolBox.Error{category: :unsupported_capability, operation: :store}}
  end
end
