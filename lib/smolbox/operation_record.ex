defmodule SmolBox.OperationRecord do
  @moduledoc false

  # Shared initial evidence for durable machine operations, independent of their
  # state machines. Each domain module validates the resulting concrete record.
  def new(module, machine, spec, fingerprint, now) do
    record =
      struct!(module,
        machine: machine,
        spec: spec,
        fingerprint: fingerprint,
        accepted_at_ms: now,
        updated_at_ms: now,
        deadline_ms: now + spec.timeout_ms
      )

    with :ok <- module.validate(record), do: {:ok, record}
  end
end
