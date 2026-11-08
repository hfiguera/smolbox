defmodule SmolBox.Embedded.HistoricalExecution do
  @moduledoc false
  alias SmolBox.Embedded.{Identity, MaterialHistory, NativeGrowth}
  alias SmolBox.{Execution, Machine, ManagedMachine}

  # A collected retained command no longer owns a machine slot. Its snapshot
  # must be a verified prefix of its authoritative parent's material history,
  # rather than an assertion about that parent's current disk sizes. The parent
  # is still independently inspected before recovery can activate the target.
  def matches?(
        %Execution{cleanup: :complete, reservation: nil} = execution,
        %ManagedMachine{} = parent
      ) do
    with :ok <- Execution.validate(execution),
         :ok <- ManagedMachine.validate(parent),
         true <- execution.managed_machine == ManagedMachine.key(parent),
         true <- parent.active_execution != Execution.key(execution),
         true <- same_source?(execution, parent),
         %Machine{backend_identity: %Identity{} = identity} <- execution.created_machine,
         {:ok, [_ | _] = history} <- NativeGrowth.transitions(parent),
         origin = hd(history).previous,
         {:ok, prefix} <- prefix(history, origin, identity.receipt),
         initial =
           Map.take(parent.backend_assignment.creation["resources"], ~w(storage_gib overlay_gib)),
         {:ok, receipt, sizes} <- MaterialHistory.chain(prefix, origin, initial),
         true <- receipt == identity.receipt do
      expected = %{
        parent.created_machine
        | storage_gb: sizes["storage_gib"],
          overlay_gb: sizes["overlay_gib"],
          backend_identity: identity
      }

      Machine.same_incarnation?(expected, execution.created_machine)
    else
      _ -> false
    end
  end

  def matches?(_, _), do: false

  defp same_source?(execution, parent) do
    # Worker lease generations advance independently when each record is claimed.
    # They fence active work; the immutable native binding and material prefix
    # establish this collected snapshot's machine identity across normal restarts.
    Enum.all?(~w(worker_id machine_name backend_assignment)a, fn key ->
      Map.fetch!(execution, key) == Map.fetch!(parent, key)
    end) and
      execution.spec.profile == parent.spec.profile and
      execution.spec.artifact == parent.spec.artifact
  end

  defp prefix(_history, origin, origin), do: {:ok, []}

  defp prefix(history, _origin, receipt) do
    case Enum.find_index(history, &(&1.receipt == receipt)) do
      nil -> :error
      index -> {:ok, Enum.take(history, index + 1)}
    end
  end
end
