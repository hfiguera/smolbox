defmodule SmolBox.Store.NativeVolumeContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.Backend.Binding
  alias SmolBox.Embedded.{Identity, MountContract, VolumeAuthority}
  alias SmolBox.Store.{BackendContract, Codec, Contract, VolumeContract}

  alias SmolBox.{
    Command,
    Error,
    Execution,
    ExecutionSpec,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    Profile,
    Volume,
    VolumePolicy
  }

  defmacro __using__(options) do
    cases =
      for {title, function} <- [
            {"native volumes persist only correlated proof and retain independent disk accounting",
             :lifecycle},
            {"native attachment reuse preserves original proof and fences old deletion",
             :attachment_reuse},
            {"native read-only attachment races commit one winner and no partial attachment",
             :attachment_race},
            {"native assigned and stopped machines retain volume holds and combined reservations",
             :assigned_holds},
            {"native retained commands preserve mounted authority without double charging volumes",
             :retained_command},
            {"native uncertain cleanup retains proof and capacity until matching completion",
             :uncertain_cleanup},
            {"native volume readers retain tombstones, selective codecs and domain fences",
             :reader_history}
          ] do
        quote do
          test unquote(title), %{adapter: adapter, store: store} do
            SmolBox.Store.NativeVolumeContract.unquote(function)(adapter, store)
          end
        end
      end

    quote do
      use ExUnit.Case, unquote(options)
      unquote_splicing(cases)
    end
  end

  defp fixture(name),
    do:
      Path.expand("../../../native/smolbox-protocol/fixtures/" <> name, __DIR__)
      |> File.read!()
      |> Jason.decode!()

  def provision do
    fixture("mounted-creation-request.json")["operation"]["create"]["volume_mounts"]
    |> hd()
    |> Map.fetch!("proof")
  end

  def record do
    proof = provision()
    backing = proof["backing"]
    {:ok, policy} = VolumePolicy.new(backing["policy"]["id"], backing["policy"]["root"])

    %{
      VolumeContract.record()
      | worker_id: backing["target_id"],
        worker_volume_id: backing["intent"]["worker_volume_id"],
        size_gb: backing["intent"]["size_gb"],
        policy: policy,
        native_authority: %VolumeAuthority{
          binding: %Binding{
            kind: :embedded,
            target_id: backing["target_id"],
            generation: backing["domain_generation"]
          }
        }
    }
  end

  def ready(adapter, store) do
    v = record()
    binding = v.native_authority.binding
    assert {:ok, %{local_volumes: 1, native_volumes: 1}} = adapter.capabilities(store)
    assert {:ok, ^binding} = adapter.bind_backend(store, v.worker_id, binding)
    assert {:ok, accepted, :inserted} = adapter.volume_accept(store, v, capacity(4))

    assert {:ok, ready, :changed} =
             adapter.volume_change(store, Volume.key(v), accepted.version, outcome(), 1001)

    ready
  end

  defp capacity(disk), do: Map.put(Contract.capacity(10), :disk_gb, disk)

  defp outcome(status \\ "provisioned", proof \\ provision()),
    do:
      {:complete_native,
       %{"result" => "volume", "volume" => %{"status" => status, "proof" => proof}}}

  defp deletion(v),
    do: %{
      "schema" => 1,
      "operation_id" => String.duplicate("d", 32),
      "provision" => v.native_authority.provision
    }

  defp roundtrip(record, version) do
    assert {:ok, bytes} = Codec.encode(record)
    prefix = "smolbox-record-v#{version}\0"
    assert String.starts_with?(bytes, prefix)
    assert {:ok, ^record} = Codec.decode(bytes)
    payload = binary_part(bytes, byte_size(prefix), byte_size(bytes) - byte_size(prefix))
    assert {:error, _} = Codec.decode("smolbox-record-v15\0" <> payload)
    assert {:error, _} = Codec.decode(bytes <> <<0>>)
    record
  end

  def lifecycle(adapter, store) do
    v = record()
    binding = v.native_authority.binding
    assert {:error, _} = adapter.volume_accept(store, v, capacity(4))
    assert {:ok, ^binding} = adapter.bind_backend(store, v.worker_id, binding)
    assert {:ok, accepted, :inserted} = adapter.volume_accept(store, v, capacity(4))
    assert {:ok, %{disk_gb: 4}} = adapter.usage(store, v.worker_id)
    assert {:error, _} = adapter.volume_change(store, Volume.key(v), 1, {:complete, :ready}, 1001)
    crossed = put_in(provision(), ~w(backing domain_generation), String.duplicate("e", 32))

    assert {:error, _} =
             adapter.volume_change(store, Volume.key(v), 1, outcome("provisioned", crossed), 1001)

    assert {:ok, ^accepted} = adapter.volume_fetch(store, Volume.key(v))

    assert {:ok, ready, :changed} =
             adapter.volume_change(store, Volume.key(v), 1, outcome(), 1001)

    assert ready.native_authority.provision == provision()
    roundtrip(ready, 20)
    assert {:ok, ^ready, :existing} = adapter.volume_accept(store, v, capacity(0))
    other = %{v | id: "extra", worker_volume_id: "sbv-" <> String.duplicate("f", 32)}

    assert {:error, %{category: :admission_exhausted}} =
             adapter.volume_accept(store, other, capacity(4))

    assert {:ok, %{disk_gb: 4}} = adapter.usage(store, v.worker_id)
  end

  def attachment_reuse(adapter, store) do
    v = ready(adapter, store)
    first = VolumeContract.machine("first")
    assert {:ok, saved} = adapter.machine(store, :accept, [first, 10])
    [attachment] = saved.native_mounts
    assert attachment.proof == v.native_authority.provision
    roundtrip(saved, 21)
    assert {:ok, held} = adapter.volume_fetch(store, Volume.key(v))
    assert held.attached_to == ManagedMachine.key(first)
    assert {:error, _} = adapter.volume_change(store, Volume.key(v), held.version, :delete, 1200)

    assert {:error, _} =
             adapter.machine(store, :accept, [VolumeContract.machine("competing"), 10])

    assert {:ok, deleted} =
             adapter.machine(store, :request, [
               ManagedMachine.key(first),
               :delete,
               saved.version,
               1200
             ])

    assert deleted.state == :deleted
    assert {:ok, free} = adapter.volume_fetch(store, Volume.key(v))
    assert free.attached_to == nil and free.native_authority == v.native_authority
    assert {:ok, %{disk_gb: 4}} = adapter.usage(store, v.worker_id)
    second = VolumeContract.machine("second")
    assert {:ok, replacement} = adapter.machine(store, :accept, [second, 10])
    assert hd(replacement.native_mounts).proof == attachment.proof

    assert {:ok, _} =
             adapter.machine(store, :request, [
               ManagedMachine.key(first),
               :delete,
               saved.version,
               1300
             ])

    assert {:ok, current} = adapter.volume_fetch(store, Volume.key(v))
    assert current.attached_to == ManagedMachine.key(second)

    assert {:ok, _} =
             adapter.machine(store, :request, [
               ManagedMachine.key(second),
               :delete,
               replacement.version,
               1400
             ])

    assert {:ok, free} = adapter.volume_fetch(store, Volume.key(v))

    assert {:ok, intent, :changed} =
             adapter.volume_change(store, Volume.key(v), free.version, :delete, 1500)

    assert {:ok, done, :changed} =
             adapter.volume_change(
               store,
               Volume.key(v),
               intent.version,
               outcome("deleted", deletion(v)),
               1501
             )

    assert done.state == :deleted
    assert {:ok, %{disk_gb: 0}} = adapter.usage(store, v.worker_id)
  end

  def attachment_race(adapter, store) do
    v = ready(adapter, store)
    partial = VolumeContract.machine("partial", ["data", "missing"])
    assert {:error, _} = adapter.machine(store, :accept, [partial, 10])
    assert {:ok, ^v} = adapter.volume_fetch(store, Volume.key(v))

    assert {:error, %{category: :not_found}} =
             adapter.machine(store, :fetch, [ManagedMachine.key(partial)])

    gate = make_ref()

    tasks =
      for id <- ["one", "two"] do
        Task.async(fn ->
          receive do
            ^gate -> adapter.machine(store, :accept, [readonly_machine(id), 10])
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, gate))
    results = Enum.map(tasks, &Task.await(&1, 5000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    {:ok, winner} = Enum.find(results, &match?({:ok, _}, &1))
    assert hd(winner.native_mounts).readonly
    assert {:ok, held} = adapter.volume_fetch(store, Volume.key(v))
    assert held.attached_to == ManagedMachine.key(winner)
    assert held.native_authority == v.native_authority
  end

  defp readonly_machine(id) do
    initial = VolumeContract.machine(id)
    spec = %{initial.spec | volumes: Enum.map(initial.spec.volumes, &%{&1 | readonly: true})}
    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, machine} = ManagedMachine.new(spec, fingerprint, initial.accepted_at_ms)
    machine
  end

  def assigned_holds(adapter, store), do: assigned(adapter, store, :stopped)

  def retained_command(adapter, store) do
    {v, machine} = assigned(adapter, store, :running)
    {:ok, command} = Command.new(["true"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: machine.scope,
        id: "mounted-command",
        artifact: machine.spec.artifact,
        profile: machine.spec.profile,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, initial} = Execution.new(spec, fingerprint, 1104)
    key = ManagedMachine.key(machine)
    assert {:ok, accepted} = adapter.machine(store, :submit, [key, initial, 10, 1104])
    assert accepted.managed_machine == key and accepted.reservation == nil
    assert accepted.backend_assignment == machine.backend_assignment
    assert accepted.created_machine.mounts == machine.mounts
    roundtrip(accepted, 21)
    assert {:ok, ^accepted} = adapter.fetch(store, Execution.key(accepted))
    assert {:ok, %{slots: 1, disk_gb: 6}} = adapter.usage(store, v.worker_id)
    assert {:ok, _} = adapter.set_worker_mode(store, v.worker_id, :draining, :any, 1105)
    assert {:ok, ^accepted} = adapter.machine(store, :submit, [key, initial, 10, 1105])
    more = %{record() | id: "new-volume", worker_volume_id: "sbv-" <> String.duplicate("f", 32)}

    assert {:error, %{category: :admission_exhausted}} =
             adapter.volume_accept(store, more, capacity(10))

    assert {:ok, held} = adapter.volume_fetch(store, Volume.key(v))
    assert held.attached_to == key and held.native_authority == v.native_authority
    assert {:ok, %{slots: 1, disk_gb: 6}} = adapter.usage(store, v.worker_id)
  end

  defp assigned(adapter, store, state) do
    v = ready(adapter, store)
    initial = VolumeContract.machine("retained")
    assert {:ok, accepted} = adapter.machine(store, :accept, [initial, 10])
    assert {:ok, _} = adapter.claim_worker(store, v.worker_id, "owner", 1100, 10_000)
    key = ManagedMachine.key(accepted)
    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "owner", 1100, 10_000])
    base = BackendContract.assignment(accepted, "mounted-retained", v.native_authority.binding)

    assignment = %{
      base
      | version: 2,
        creation: MountContract.attach(base.creation, accepted.native_mounts)
    }

    assert {:ok, reserved} =
             adapter.machine(store, :reserve, [
               key,
               Contract.guard(claimed),
               {v.worker_id, "mounted-retained", capacity(6), assignment},
               1100
             ])

    assert {:ok, %{slots: 1, disk_gb: 6}} = adapter.usage(store, v.worker_id)

    assert {:ok, unknown} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(reserved),
               [state: :unknown, last_error: %Error{category: :unknown, operation: :create}],
               1101
             ])

    roundtrip(unknown, 21)
    assert {:ok, held} = adapter.volume_fetch(store, Volume.key(v))
    assert held.attached_to == key

    assert {:error, _} =
             adapter.volume_change(store, Volume.key(v), held.version, :resolve_delete, 1102)

    receipt =
      fixture("created-v2.json")["outcome"]["receipt"]
      |> Map.merge(%{
        "target_id" => v.worker_id,
        "domain_generation" => assignment.binding.generation,
        "name" => assignment.creation["name"],
        "owner_token" => assignment.creation["owner_token"],
        "incarnation" => assignment.creation["incarnation"]
      })

    observed = %Machine{
      name: assignment.creation["name"],
      state: state,
      created_at: nil,
      cpus: 1,
      memory_mb: 256,
      storage_gb: 1,
      overlay_gb: 1,
      mounts: accepted.mounts,
      backend_identity: %Identity{
        receipt: receipt,
        pid_identity: if(state == :running, do: [123, 456])
      }
    }

    assert {:ok, stopped} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(unknown),
               [
                 state: state,
                 operation: nil,
                 phase: nil,
                 created_machine: observed,
                 observed_machine: observed
               ],
               1103
             ])

    assert stopped.reservation == reserved.reservation
    assert stopped.native_mounts == accepted.native_mounts
    assert {:ok, ^held} = adapter.volume_fetch(store, Volume.key(v))
    assert {:ok, %{slots: 1, disk_gb: 6}} = adapter.usage(store, v.worker_id)

    assert {:error, _} =
             adapter.machine(store, :accept, [VolumeContract.machine("competing"), 10])

    assert {:error, _} = adapter.bind_backend(store, v.worker_id, :http)
    assert {:ok, records, nil} = adapter.backend_assignments(store, v.worker_id, nil, 10)
    assert stopped in records and held in records
    roundtrip(stopped, 21)
    assert Profile.resources(stopped.spec.profile).disk_gb + Volume.resources(held).disk_gb == 6
    {v, stopped}
  end

  def uncertain_cleanup(adapter, store) do
    v = ready(adapter, store)

    assert {:ok, intent, :changed} =
             adapter.volume_change(store, Volume.key(v), v.version, :delete, 1100)

    assert {:ok, unknown, :changed} =
             adapter.volume_change(
               store,
               Volume.key(v),
               intent.version,
               {:unknown, %Error{category: :unknown, operation: :volume}},
               1101
             )

    assert unknown.native_authority == v.native_authority
    assert {:ok, %{disk_gb: 4}} = adapter.usage(store, v.worker_id)

    assert {:ok, resolving, :changed} =
             adapter.volume_change(store, Volume.key(v), unknown.version, :resolve_delete, 1200)

    crossed = put_in(deletion(v), ~w(provision backing inode), 7)

    assert {:error, _} =
             adapter.volume_change(
               store,
               Volume.key(v),
               resolving.version,
               outcome("deleted", crossed),
               1201
             )

    assert {:error, _} =
             adapter.volume_change(
               store,
               Volume.key(v),
               resolving.version,
               {:complete, :deleted},
               1201
             )

    assert {:ok, ^resolving} = adapter.volume_fetch(store, Volume.key(v))
    assert {:ok, %{disk_gb: 4}} = adapter.usage(store, v.worker_id)

    assert {:ok, done, :changed} =
             adapter.volume_change(
               store,
               Volume.key(v),
               resolving.version,
               outcome("deleted", deletion(v)),
               1202
             )

    assert done.native_authority.provision == v.native_authority.provision
    assert done.native_authority.deletion == deletion(v)
    assert {:ok, %{disk_gb: 0}} = adapter.usage(store, v.worker_id)
    roundtrip(done, 20)
  end

  def reader_history(adapter, store) do
    v = ready(adapter, store)

    assert {:ok, intent, :changed} =
             adapter.volume_change(store, Volume.key(v), v.version, :delete, 1100)

    assert {:ok, done, :changed} =
             adapter.volume_change(
               store,
               Volume.key(v),
               intent.version,
               outcome("deleted", deletion(v)),
               1101
             )

    assert {:ok, [^done], nil} = adapter.volume_list(store, v.scope, nil, 10)
    assert {:ok, [^done], nil} = adapter.backend_assignments(store, v.worker_id, nil, 10)
    assert {:ok, ^done, :existing} = adapter.volume_accept(store, record(), capacity(0))
    binding = v.native_authority.binding
    assert {:ok, ^binding} = adapter.bind_backend(store, v.worker_id, binding)
    assert {:error, _} = adapter.bind_backend(store, v.worker_id, :http)

    assert {:error, _} =
             adapter.bind_backend(store, v.worker_id, %{
               binding
               | generation: String.duplicate("e", 32)
             })

    assert {:ok, %{disk_gb: 0}} = adapter.usage(store, v.worker_id)
    roundtrip(done, 20)
  end
end
