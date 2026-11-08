defmodule SmolBox.Embedded.NativeGrowth do
  @moduledoc false
  alias SmolBox.{DiskExpansion, Execution, Machine, ManagedMachine}

  alias SmolBox.Embedded.{
    CaptureTransition,
    GrowthTransition,
    Identity,
    MaterialHistory,
    NativeBranchAuthority,
    NativeBranchHistory,
    NativePreparedBranchRetirement
  }

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

  def current_identity(
        %{
          __struct__: ManagedMachine,
          branch: %{native_authority: %{completion: completion}}
        } = record
      )
      when not is_nil(completion), do: history_identity(record)

  def current_identity(%{
        __struct__: ManagedMachine,
        disk_expansions: history,
        captures: captures,
        native_branch_history: branches,
        created_machine: created
      })
      when map_size(history) == 0 and map_size(captures) == 0 and map_size(branches) == 0,
      do: if(created, do: {:ok, created.backend_identity}, else: {:ok, nil})

  def current_identity(%{__struct__: ManagedMachine} = record), do: history_identity(record)

  def current_identity(%{__struct__: Execution, created_machine: created}),
    do: {:ok, if(created, do: created.backend_identity)}

  defp history_identity(record) do
    with {:ok, receipt, _sizes, last} <- head(record),
         do:
           {:ok,
            %Identity{
              receipt: receipt,
              transition: last,
              material_history: capture_history(record)
            }}
  end

  def record_valid?(
        %{__struct__: ManagedMachine, branch: %{native_authority: %{completion: completion}}} =
          record
      )
      when not is_nil(completion), do: history_record?(record)

  def record_valid?(
        %{
          __struct__: ManagedMachine,
          disk_expansions: history,
          captures: captures,
          native_branch_history: branches
        } = record
      )
      when map_size(history) == 0 and map_size(captures) == 0 and map_size(branches) == 0,
      do: unchanged?(record.created_machine) and unchanged?(record.observed_machine)

  def record_valid?(%{__struct__: ManagedMachine} = record), do: history_record?(record)

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
        execution_history?(identity, transition, machine, profile)
    end
  end

  def record_valid?(_record), do: false

  defp history_record?(record) do
    with true <- unchanged?(record.created_machine),
         {:ok, receipt, sizes, last} <- head(record) do
      (record.disk_sizes == %{storage_gb: sizes["storage_gib"], overlay_gb: sizes["overlay_gib"]} or
         (record.disk_sizes == nil and sizes == sizes(record.created_machine))) and
        observation?(record.observed_machine, receipt, last)
    else
      _ -> false
    end
  end

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

  def head(record) do
    with %Machine{backend_identity: %Identity{} = origin} <- record.created_machine,
         true <- Identity.valid?(origin),
         {:ok, transitions} <- committed_all(record),
         {:ok, receipt, sizes} <-
           MaterialHistory.chain(transitions, origin.receipt, sizes(record.created_machine)) do
      {:ok, receipt, sizes, List.last(transitions)}
    else
      _ -> :error
    end
  end

  defp execution_history?(
         %{material_history: nil} = identity,
         %GrowthTransition{} = transition,
         machine,
         _profile
       ),
       do:
         Identity.valid?(identity) and
           sizes(machine) == Map.take(transition.change, ~w(storage_gib overlay_gib))

  defp execution_history?(identity, _transition, machine, profile) do
    with true <- Identity.valid?(identity),
         history when is_list(history) and history != [] <- identity.material_history,
         {:ok, receipt, expected} <-
           MaterialHistory.chain(history, hd(history).previous, sizes(profile)) do
      receipt == identity.receipt and sizes(machine) == expected
    else
      _ -> false
    end
  end

  defp capture_history(record) do
    with {:ok, transitions} <- committed_all(record),
         true <- Enum.any?(transitions, &MaterialHistory.requires_history?/1),
         do: transitions,
         else: (_ -> nil)
  end

  def transitions(record), do: committed_all(record)

  def capture_profile(record, capture) do
    with {:ok, transitions} <- committed_all(record),
         %CaptureTransition{} = proof <- capture.native_transition,
         before =
           Enum.filter(
             transitions,
             &(&1.receipt["material"]["revision"] <= proof.previous["material"]["revision"])
           ),
         {:ok, _receipt, expected} <-
           MaterialHistory.chain(
             before,
             record.created_machine.backend_identity.receipt,
             sizes(record.created_machine)
           ) do
      struct!(record.spec.profile,
        storage_gb: expected["storage_gib"],
        overlay_gb: expected["overlay_gib"]
      )
    else
      _ -> nil
    end
  end

  defp committed_all(record) do
    with {:ok, growth} <- committed(record.disk_expansions),
         {:ok, captures} <- committed_captures(record.captures),
         {:ok, branches} <- NativeBranchHistory.transitions(record),
         {:ok, release} <- NativeBranchAuthority.transitions(record) do
      transitions =
        Enum.sort_by(
          growth ++ captures ++ branches ++ release,
          & &1.receipt["material"]["revision"]
        )

      if NativePreparedBranchRetirement.history?(record, transitions),
        do: {:ok, transitions},
        else: :error
    end
  end

  defp committed_captures(captures) do
    Enum.reduce_while(captures, {:ok, []}, fn {id, capture}, {:ok, history} ->
      cond do
        SmolBox.CheckpointCapture.validate(capture) != :ok or capture.spec.id != id ->
          {:halt, :error}

        capture.native_transition != nil ->
          {:cont, {:ok, [capture.native_transition | history]}}

        capture.state in [:captured, :completed] ->
          {:halt, :error}

        true ->
          {:cont, {:ok, history}}
      end
    end)
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
