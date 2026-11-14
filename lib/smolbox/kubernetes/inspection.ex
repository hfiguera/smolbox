defmodule SmolBox.Kubernetes.Inspection do
  @moduledoc false
  alias SmolBox.Kubernetes.{Guard, Pod, Receipt}
  alias SmolBox.Machine

  def observe(
        operation,
        %{backend_receipt: %Receipt{phase: :ready}, created_machine: %Machine{}} = record
      ) do
    with :ok <- Guard.check(operation, record),
         do: {:ok, %{record.created_machine | state: :running}}
  end

  def observe(operation, record), do: Pod.observe(operation, record)
end
