defmodule SmolBox.Embedded.NativeGrowth do
  @moduledoc false
  alias SmolBox.{DiskExpansion, Execution, Machine, ManagedMachine}
  alias SmolBox.Embedded.{GrowthTransition, Identity}

  def request(expansion),
    do: %{
      "storage_gib" => expansion.request[:storage_gb],
      "overlay_gib" => expansion.request[:overlay_gb]
    }

  def sizes(value), do: %{"storage_gib" => value.storage_gb, "overlay_gib" => value.overlay_gb}

  def intent(%{__struct__: ManagedMachine, active_expansion: id} = record) when not is_nil(id) do
    expansion = record.disk_expansions[id]

    case head(record) do
      {:ok, receipt, previous, _last} ->
        %{
          id: id,
          state: expansion.state,
          receipt: receipt,
          request: request(expansion),
          previous: previous,
          targets: sizes(expansion)
        }

      _ ->
        nil
    end
  end

  def intent(_record), do: nil

  def current_identity(%{
        __struct__: ManagedMachine,
        disk_expansions: history,
        created_machine: created
      })
      when map_size(history) == 0,
      do: if(created, do: {:ok, created.backend_identity}, else: {:ok, nil})

  def current_identity(%{__struct__: ManagedMachine} = record) do
    with {:ok, receipt, _sizes, last} <- head(record),
         do: {:ok, %Identity{receipt: receipt, transition: last}}
  end

  def current_identity(%{__struct__: Execution, created_machine: created}),
    do: {:ok, if(created, do: created.backend_identity)}

  def record_valid?(%{__struct__: ManagedMachine, disk_expansions: history} = record)
      when map_size(history) == 0,
      do: unchanged?(record.created_machine) and unchanged?(record.observed_machine)

  def record_valid?(%{__struct__: ManagedMachine} = record) do
    with true <- unchanged?(record.created_machine),
         {:ok, receipt, sizes, last} <- head(record) do
      record.disk_sizes == %{storage_gb: sizes["storage_gib"], overlay_gb: sizes["overlay_gib"]} and
        observation?(record.observed_machine, receipt, last)
    else
      _ -> false
    end
  end

  def record_valid?(%{__struct__: Execution, managed_machine: nil} = record),
    do: unchanged?(record.created_machine)

  def record_valid?(%{__struct__: Execution, created_machine: nil}), do: true

  def record_valid?(%{
        __struct__: Execution,
        created_machine: %Machine{backend_identity: %Identity{} = identity} = machine,
        spec: %{profile: profile}
      }) do
    case identity.transition do
      nil ->
        unchanged?(machine) and sizes(machine) == sizes(profile)

      transition ->
        Identity.valid?(identity) and
          sizes(machine) == Map.take(transition.change, ~w(storage_gib overlay_gib))
    end
  end

  def record_valid?(_record), do: false

  def transition?(
        record,
        expansion,
        %Machine{backend_identity: %Identity{transition: transition} = identity} = observed
      ) do
    with {:ok, receipt, previous_sizes, _last} <- head(record),
         true <- Identity.valid?(identity) and observed.state in [:created, :stopped] do
      GrowthTransition.bound?(
        transition,
        receipt,
        expansion.id,
        request(expansion),
        previous_sizes,
        sizes(expansion)
      ) and
        identity.receipt == transition.receipt
    else
      _ -> false
    end
  end

  def transition?(_record, _expansion, _observed), do: false

  defp head(record) do
    with %Machine{backend_identity: %Identity{} = origin} <- record.created_machine,
         true <- Identity.valid?(origin),
         {:ok, transitions} <- committed(record.disk_expansions),
         {:ok, receipt, sizes} <-
           GrowthTransition.chain(transitions, origin.receipt, sizes(record.created_machine)) do
      {:ok, receipt, sizes, List.last(transitions)}
    else
      _ -> :error
    end
  end

  defp committed(history) do
    Enum.reduce_while(history, {:ok, []}, fn {id, expansion}, {:ok, transitions} ->
      entry(expansion, id, transitions)
    end)
    |> case do
      {:ok, transitions} -> {:ok, Enum.sort_by(transitions, & &1.receipt["material"]["revision"])}
      :error -> :error
    end
  end

  defp entry(
         %{__struct__: DiskExpansion, id: id, state: state, native_transition: transition} =
           expansion,
         id,
         transitions
       )
       when state in [:completed, :resolved] do
    if committed_transition?(expansion, transition),
      do: {:cont, {:ok, [transition | transitions]}},
      else: {:halt, :error}
  end

  defp entry(%{__struct__: DiskExpansion, id: id, native_transition: nil}, id, transitions),
    do: {:cont, {:ok, transitions}}

  defp entry(_expansion, _id, _transitions), do: {:halt, :error}

  defp committed_transition?(expansion, transition),
    do:
      GrowthTransition.valid?(transition) and
        transition.change["operation_id"] == expansion.id and
        transition.change["request"] == request(expansion) and
        Map.take(transition.change, ~w(storage_gib overlay_gib)) == sizes(expansion)

  # Preserve historical v16/v17 structural receipt acceptance when there is no
  # growth history. New history must independently prove a canonical root and
  # every link; an old bare receipt is never automatically promoted into it.
  defp unchanged?(nil), do: true
  defp unchanged?(%Machine{backend_identity: %Identity{transition: nil}}), do: true
  defp unchanged?(_machine), do: false

  defp observation?(%Machine{backend_identity: %Identity{} = identity}, receipt, transition),
    do:
      Identity.valid?(identity) and identity.receipt == receipt and
        identity.transition == transition

  defp observation?(_machine, _receipt, _transition), do: false
end
