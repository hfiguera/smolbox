defmodule SmolBox.Store.SourceContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{ArtifactPreparation, ManagedMachine, ManagedMachineSpec, Source}
  alias SmolBox.Store.{Contract, MachineContract}

  def source do
    {:ok, source} =
      Source.registry(
        id: "registry-python",
        architecture: "x86_64",
        reference: "registry.example.com/python@sha256:" <> String.duplicate("a", 64),
        content_sha256: String.duplicate("b", 64),
        credential_ref: "registry-reader"
      )

    source
  end

  def record(id \\ "registry-machine") do
    original = MachineContract.record(id)
    spec = %{original.spec | artifact: Source.artifact(source())}
    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)
    record
  end

  def preparation do
    {:ok, result} =
      ArtifactPreparation.from_wire(source(), %{
        "digest" => "sha256:" <> source().content_sha256,
        "sizeBytes" => 123,
        "alreadyCached" => false
      })

    result
  end

  def acceptance(adapter, store) do
    assert {:ok, %{registry_sources: 1}} = adapter.capabilities(store)
    record = record()
    assert {:ok, ^record} = adapter.machine(store, :accept, [record, 10])
    assert {:ok, ^record} = adapter.machine(store, :accept, [record, 10])
    assert {:ok, ^record} = adapter.machine(store, :fetch, [ManagedMachine.key(record)])
    changed_source = %{source() | content_sha256: String.duplicate("c", 64)}
    changed_spec = %{record.spec | artifact: Source.artifact(changed_source)}
    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(changed_spec, :binary.copy(<<1>>, 32))
    {:ok, changed} = ManagedMachine.new(changed_spec, fingerprint, 1000)

    assert {:error, %{category: :identity_conflict}} =
             adapter.machine(store, :accept, [changed, 10])
  end

  def exclusion(adapter, store) do
    first = record("first")
    second = record("second")

    for record <- [first, second],
        do: assert({:ok, ^record} = adapter.machine(store, :accept, [record, 10]))

    assert {:ok, _lease} = adapter.claim_worker(store, "worker", "owner", 1000, 1000)
    first = reserve(adapter, store, first, "owner", 1000)

    assert {:ok, second} =
             adapter.machine(store, :claim, [ManagedMachine.key(second), "owner", 1000, 1000])

    assert {:error, %{category: :admission_exhausted}} = do_reserve(adapter, store, second, 1000)

    assert {:ok, first} =
             write(adapter, store, first, [phase: :preparing, operation_deadline_ms: 1500], 1000)

    assert {:ok, first} = write(adapter, store, first, [state: :unknown, phase: :uncertain], 1100)
    assert {:error, _} = write(adapter, store, first, [operation: nil, phase: nil], 1100)
    assert {:ok, _lease} = adapter.claim_worker(store, "worker", "next", 2100, 1000)

    assert {:ok, second} =
             adapter.machine(store, :claim, [ManagedMachine.key(second), "next", 2100, 1000])

    assert {:error, %{category: :admission_exhausted}} = do_reserve(adapter, store, second, 2100)

    assert {:ok, first} =
             adapter.machine(store, :claim, [ManagedMachine.key(first), "next", 2100, 1000])

    assert {:ok, first} = write(adapter, store, first, [state: :missing], 2100)
    assert {:error, %{category: :admission_exhausted}} = do_reserve(adapter, store, second, 2100)

    assert {:ok, %{state: :deleted}} =
             adapter.machine(store, :resolve, [
               ManagedMachine.key(first),
               Contract.guard(first),
               :absent,
               2100
             ])

    assert {:ok, reserved} = do_reserve(adapter, store, second, 2100)
    assert reserved.spec.artifact == second.spec.artifact
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
  end

  def preparation_history(adapter, store) do
    record = record()
    assert {:ok, ^record} = adapter.machine(store, :accept, [record, 10])
    assert {:ok, _lease} = adapter.claim_worker(store, "worker", "owner", 1000, 1000)
    record = reserve(adapter, store, record, "owner", 1000)

    assert {:ok, record} =
             write(adapter, store, record, [phase: :prepared, preparation: preparation()], 1000)

    assert {:ok, ^record} = adapter.machine(store, :fetch, [ManagedMachine.key(record)])
    assert {:error, _} = write(adapter, store, record, [preparation: nil], 1000)

    assert {:error, _} =
             write(
               adapter,
               store,
               record,
               [preparation: %{preparation() | content_sha256: String.duplicate("c", 64)}],
               1000
             )

    assert {:ok, ^record} = adapter.machine(store, :fetch, [ManagedMachine.key(record)])
  end

  def concurrent_reservations(adapter, store) do
    assert {:ok, _lease} = adapter.claim_worker(store, "worker", "owner", 1000, 1000)

    records =
      for id <- ["parallel-one", "parallel-two"] do
        record = record(id)
        assert {:ok, ^record} = adapter.machine(store, :accept, [record, 10])

        assert {:ok, claimed} =
                 adapter.machine(store, :claim, [ManagedMachine.key(record), "owner", 1000, 1000])

        claimed
      end

    results =
      records
      |> Task.async_stream(&do_reserve(adapter, store, &1, 1000), max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _record}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{category: :admission_exhausted}}, &1)) == 1
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
  end

  defp reserve(adapter, store, record, owner, now) do
    assert {:ok, claimed} =
             adapter.machine(store, :claim, [ManagedMachine.key(record), owner, now, 1000])

    assert {:ok, reserved} = do_reserve(adapter, store, claimed, now)
    reserved
  end

  defp do_reserve(adapter, store, record, now),
    do:
      adapter.machine(store, :reserve, [
        ManagedMachine.key(record),
        Contract.guard(record),
        {"worker", "vm-" <> record.id, Contract.capacity(3)},
        now
      ])

  defp write(adapter, store, record, changes, now),
    do:
      adapter.machine(store, :write, [
        ManagedMachine.key(record),
        Contract.guard(record),
        changes,
        now
      ])

  defmacro __using__(options) do
    quote do
      use ExUnit.Case, unquote(options)

      for scenario <- [:acceptance, :exclusion, :preparation_history, :concurrent_reservations] do
        @source_scenario scenario
        test "registry source contract: #{scenario}", %{adapter: adapter, store: store} do
          apply(SmolBox.Store.SourceContract, @source_scenario, [adapter, store])
        end
      end
    end
  end
end
