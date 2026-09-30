defmodule SmolBox.Store.VolumeContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{ManagedMachine, ManagedMachineSpec, Volume, VolumeMount, VolumePolicy}
  alias SmolBox.Store.{Codec, Contract, MachineContract}

  def record(id \\ "data") do
    {:ok, p} = VolumePolicy.new("local", "/approved/volumes")

    %Volume{
      scope: "contract",
      id: id,
      worker_id: "worker",
      worker_volume_id: "sbv-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      policy: p,
      size_gb: 2,
      fingerprint: SmolBox.Files.sha256(id),
      accepted_at_ms: 1000,
      updated_at_ms: 1000
    }
  end

  def ready(a, s, id \\ "data") do
    v = record(id)
    {:ok, saved, :inserted} = a.volume_accept(s, v, Contract.capacity(10))

    {:ok, ready, :changed} =
      a.volume_change(s, Volume.key(v), saved.version, {:complete, :ready}, 1001)

    ready
  end

  def machine(id, volumes \\ ["data"]) do
    m = MachineContract.record(id)

    mounts =
      Enum.map(volumes, fn id ->
        {:ok, ref} = VolumeMount.new(id, "/mnt/volumes/" <> id)
        ref
      end)
      |> Enum.sort_by(& &1.target)

    spec = %{m.spec | volumes: mounts}
    {:ok, fp} = ManagedMachineSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, m} = ManagedMachine.new(spec, fp, 1100)
    m
  end

  def lifecycle(a, s) do
    v = record()
    assert {:ok, first, :inserted} = a.volume_accept(s, v, Contract.capacity(1))

    assert {:ok, ^first, :existing} =
             a.volume_accept(
               s,
               %{v | worker_volume_id: record().worker_volume_id},
               Contract.capacity(1)
             )

    assert {:error, %{category: :identity_conflict}} =
             a.volume_accept(
               s,
               %{v | fingerprint: SmolBox.Files.sha256("changed")},
               Contract.capacity(10)
             )

    assert {:error, %{category: :admission_exhausted}} =
             a.volume_accept(s, record("more"), Contract.capacity(1))

    assert {:ok, %{disk_gb: 2}} = a.usage(s, "worker")
    {:ok, ready, _} = a.volume_change(s, Volume.key(v), v.version, {:complete, :ready}, 1001)
    m = machine("one")
    assert {:ok, attached} = a.machine(s, :accept, [m, 10])
    assert {:ok, ^attached} = a.machine(s, :accept, [m, 10])
    {:ok, held} = a.volume_fetch(s, Volume.key(v))
    assert held.attached_to == ManagedMachine.key(m)
    assert {:error, _} = a.volume_change(s, Volume.key(v), held.version, :delete, 1100)
    assert {:error, _} = a.machine(s, :accept, [machine("two"), 10])

    assert {:ok, deleted} =
             a.machine(s, :request, [ManagedMachine.key(m), :delete, attached.version, 1200])

    assert deleted.state == :deleted
    {:ok, free} = a.volume_fetch(s, Volume.key(v))
    assert free.attached_to == nil and free.version > ready.version
    assert {:ok, replacement} = a.machine(s, :accept, [machine("two"), 10])
    # Retrying the old machine's deletion must not release the new attachment.
    assert {:ok, _} =
             a.machine(s, :request, [ManagedMachine.key(m), :delete, attached.version, 1300])

    {:ok, current} = a.volume_fetch(s, Volume.key(v))
    assert current.attached_to == ManagedMachine.key(replacement)

    {:ok, _} =
      a.machine(s, :request, [ManagedMachine.key(replacement), :delete, replacement.version, 1400])

    {:ok, free} = a.volume_fetch(s, Volume.key(v))
    {:ok, intent, :changed} = a.volume_change(s, Volume.key(v), free.version, :delete, 1500)
    assert {:ok, _, :existing} = a.volume_change(s, Volume.key(v), free.version, :delete, 1500)

    assert {:ok, tombstone, :changed} =
             a.volume_change(s, Volume.key(v), intent.version, {:complete, :deleted}, 1501)

    assert {:ok, %{disk_gb: 0}} = a.usage(s, "worker")
    assert {:ok, ^tombstone, :existing} = a.volume_accept(s, v, Contract.capacity(1))
    assert {:ok, [^tombstone], nil} = a.volume_list(s, "contract", nil, 10)
    assert {:ok, bytes = <<"smolbox-record-v15\0", _::binary>>} = Codec.encode(tombstone)
    assert {:ok, ^tombstone} = Codec.decode(bytes)
  end

  def attachment_race(a, s) do
    v = ready(a, s)
    gate = make_ref()

    tasks =
      for id <- ["one", "two"],
          do:
            Task.async(fn ->
              receive do
                ^gate -> a.machine(s, :accept, [machine(id), 10])
              end
            end)

    Enum.each(tasks, &send(&1.pid, gate))
    results = Enum.map(tasks, &Task.await(&1, 5000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{category: :admission_exhausted}}, &1)) == 1
    {:ok, held} = a.volume_fetch(s, Volume.key(v))
    assert {:ok, m} = a.machine(s, :fetch, [held.attached_to])
    assert hd(m.mounts).source == Volume.path(v)
  end

  def rollback(a, s) do
    v = ready(a, s)
    assert {:error, _} = a.machine(s, :accept, [machine("invalid", ["data", "missing"]), 10])
    assert {:ok, ^v} = a.volume_fetch(s, Volume.key(v))
    assert {:error, %{category: :not_found}} = a.machine(s, :fetch, [{"contract", "invalid"}])
    assert {:ok, _} = a.set_worker_mode(s, "worker", :draining, :any, 1100)

    assert {:error, %{category: :admission_exhausted}} =
             a.machine(s, :accept, [machine("blocked"), 10])

    assert {:ok, ^v} = a.volume_fetch(s, Volume.key(v))

    assert {:error, %{category: :admission_exhausted}} =
             a.volume_accept(s, record("new"), Contract.capacity(10))

    {:ok, report} = a.worker_maintenance(s, "worker", nil, 10, 1200)
    assert [%{kind: :volume}] = report.records
    assert report.assessment == :blocked and report.reserved.disk_gb == 2
  end

  def uncertain(a, s) do
    v = record()
    {:ok, _, :inserted} = a.volume_accept(s, v, Contract.capacity(10))
    assert {:error, _} = a.machine(s, :accept, [machine("blocked"), 10])
    {:ok, cleaning, _} = a.volume_change(s, Volume.key(v), v.version, :resolve_delete, 1100)

    assert {:error, %{category: :stale_version}} =
             a.volume_change(s, Volume.key(v), v.version, {:complete, :ready}, 1200)

    assert {:ok, %{disk_gb: 2}} = a.usage(s, "worker")

    {:ok, deleted, _} =
      a.volume_change(s, Volume.key(v), cleaning.version, {:complete, :deleted}, 1300)

    assert deleted.state == :deleted
  end

  def delete_attachment_race(a, s) do
    v = ready(a, s)
    gate = make_ref()

    ops = [
      fn -> a.machine(s, :accept, [machine("racing"), 10]) end,
      fn -> a.volume_change(s, Volume.key(v), v.version, :delete, 1100) end
    ]

    tasks =
      Enum.map(ops, fn op ->
        Task.async(fn ->
          receive do
            ^gate -> op.()
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, gate))
    results = Enum.map(tasks, &Task.await(&1, 5000))
    assert Enum.count(results, &(elem(&1, 0) == :ok)) == 1
    assert Enum.count(results, &(elem(&1, 0) == :error)) == 1
    {:ok, current} = a.volume_fetch(s, Volume.key(v))

    assert (current.state == :deleting and current.attached_to == nil) or
             (current.state == :ready and current.attached_to == {"contract", "racing"})

    assert {:ok, %{disk_gb: 2}} = a.usage(s, "worker")
  end

  def capacity_race(a, s) do
    gate = make_ref()

    tasks =
      for id <- ["one", "two"] do
        Task.async(fn ->
          receive do
            ^gate -> a.volume_accept(s, record(id), Contract.capacity(1))
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, gate))
    results = Enum.map(tasks, &Task.await(&1, 5000))
    assert Enum.count(results, &match?({:ok, _, :inserted}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{category: :admission_exhausted}}, &1)) == 1
    assert {:ok, %{disk_gb: 2}} = a.usage(s, "worker")
  end

  def worker_scope_and_pages(a, s) do
    v = ready(a, s)
    other = %{record("other") | worker_id: "elsewhere"}
    {:ok, _, :inserted} = a.volume_accept(s, other, Contract.capacity(10))

    {:ok, other, _} =
      a.volume_change(s, Volume.key(other), other.version, {:complete, :ready}, 1001)

    assert {:error, %{category: :identity_conflict}} =
             a.machine(s, :accept, [machine("cross-worker", ["data", "other"]), 10])

    assert {:ok, ^v} = a.volume_fetch(s, Volume.key(v))
    assert {:ok, ^other} = a.volume_fetch(s, Volume.key(other))
    assert {:ok, [^v], "data"} = a.volume_list(s, "contract", nil, 1)
    assert {:ok, [^other], nil} = a.volume_list(s, "contract", "data", 1)
    assert {:ok, [], nil} = a.volume_list(s, "another-scope", nil, 1)
    assert {:error, _} = a.volume_list(s, "contract", nil, 101)
  end

  defmacro __using__(options) do
    tests =
      for scenario <- [
            :lifecycle,
            :attachment_race,
            :rollback,
            :uncertain,
            :delete_attachment_race,
            :capacity_race,
            :worker_scope_and_pages
          ] do
        quote do
          test unquote("local volumes: #{scenario}"), %{adapter: a, store: s} do
            SmolBox.Store.VolumeContract.unquote(scenario)(a, s)
          end
        end
      end

    quote do
      use ExUnit.Case, unquote(options)
      unquote_splicing(tests)
    end
  end
end
