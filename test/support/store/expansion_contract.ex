defmodule SmolBox.Store.ExpansionContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{DiskExpansion, ManagedMachine}
  alias SmolBox.Store.{Codec, Contract, MachineContract}

  defmacro __using__(options) do
    cases =
      for {label, function} <- [
            {"disk growth reserves before dispatch and preserves creation and command identity",
             :lifecycle},
            {"growth rejects invalid sizes, stale versions, active work and drained admission",
             :rejections},
            {"partial growth retains accounting and blocks reuse until explicit resolution",
             :unknown},
            {"competing growth requests serialize against worker capacity", :race}
          ] do
        quote do
          test(unquote(label), %{adapter: a, store: s},
            do: SmolBox.Store.ExpansionContract.unquote(function)(a, s)
          )
        end
      end

    quote do
      use ExUnit.Case, unquote(options)
      unquote_splicing(cases)
    end
  end

  def stopped(a, s, id \\ "computer") do
    r = MachineContract.running_named(a, s, id)

    {:ok, r} =
      a.machine(s, :write, [
        ManagedMachine.key(r),
        Contract.guard(r),
        [state: :stopped, observed_machine: %{r.observed_machine | state: :stopped}],
        1000
      ])

    r
  end

  def accept(
        a,
        s,
        m,
        id \\ "grow",
        targets \\ %{storage_gb: 3, overlay_gb: 2},
        capacity \\ Contract.capacity(20)
      ),
      do:
        a.machine(s, :expansion_accept, [
          ManagedMachine.key(m),
          id,
          m.version,
          targets,
          capacity,
          1100
        ])

  def advance(a, s, m, outcome) do
    r = m.disk_expansions[m.active_expansion]

    a.machine(s, :expansion_advance, [
      ManagedMachine.key(m),
      Contract.guard(m),
      r.id,
      r.state,
      outcome,
      1200
    ])
  end

  def lifecycle(a, s) do
    original = stopped(a, s)
    {:ok, pending} = accept(a, s, original)
    assert {:ok, %{disk_gb: 5}} = a.usage(s, "worker")
    assert {:ok, ^pending} = accept(a, s, original)

    assert {:error, %{category: :identity_conflict}} =
             accept(a, s, original, "grow", %{storage_gb: 4})

    assert {:error, %{category: :admission_exhausted}} =
             a.machine(s, :request, [ManagedMachine.key(pending), :start, pending.version, 1100])

    {:ok, sent} = advance(a, s, pending, :dispatch)
    target = %{sent.created_machine | state: :stopped, storage_gb: 3, overlay_gb: 2}
    {:ok, done} = advance(a, s, sent, {:complete, target})
    assert done.spec == original.spec and done.fingerprint == original.fingerprint
    assert done.created_machine == original.created_machine
    assert DiskExpansion.matches?(done, target)
    assert done.disk_expansions["grow"].state == :completed
    assert {:ok, bytes = <<"smolbox-record-v14\0", _::binary>>} = Codec.encode(done)
    assert {:ok, ^done} = Codec.decode(bytes)

    assert {:error, _} =
             Codec.decode(
               String.replace_prefix(bytes, "smolbox-record-v14", "smolbox-record-v13")
             )

    {:ok, running} =
      a.machine(s, :write, [
        ManagedMachine.key(done),
        Contract.guard(done),
        [state: :running, observed_machine: %{target | state: :running}],
        1200
      ])

    assert {:ok, command} =
             a.machine(s, :submit, [
               ManagedMachine.key(done),
               Contract.record("after-growth"),
               10,
               1200
             ])

    assert command.created_machine.storage_gb == 3
    assert {:ok, encoded = <<"smolbox-record-v14\0", _::binary>>} = Codec.encode(command)
    assert {:ok, ^command} = Codec.decode(encoded)
    refute DiskExpansion.matches?(running, %{target | created_at: target.created_at + 1})
  end

  def rejections(a, s) do
    r = stopped(a, s)

    for targets <- [%{storage_gb: 0}, %{storage_gb: 65}, %{storage_gb: 1}, %{}] do
      assert {:error, %{category: :validation}} = accept(a, s, r, "invalid", targets)
    end

    assert {:error, %{category: :stale_version}} = accept(a, s, %{r | version: r.version - 1})

    assert {:error, %{category: :admission_exhausted}} =
             accept(a, s, r, "full", %{storage_gb: 3}, %{Contract.capacity(20) | disk_gb: 2})

    {:ok, _} = a.set_worker_mode(s, "worker", :draining, :any, 1100)
    assert {:error, %{category: :admission_exhausted}} = accept(a, s, r)
    assert {:ok, %{disk_gb: 2}} = a.usage(s, "worker")
    {:ok, _} = a.set_worker_mode(s, "worker", :active, 1, 1100)
    {:ok, pending} = accept(a, s, r)
    {:ok, _} = a.set_worker_mode(s, "worker", :draining, :any, 1100)
    assert {:ok, ^pending} = accept(a, s, r)
    assert {:ok, _} = advance(a, s, pending, :dispatch)
  end

  def unknown(a, s) do
    r = stopped(a, s)
    {:ok, pending} = accept(a, s, r)
    {:ok, sent} = advance(a, s, pending, :dispatch)

    {:ok, unknown} =
      advance(
        a,
        s,
        sent,
        {:unknown, %SmolBox.Error{category: :transport, operation: :expand_disks}}
      )

    partial = %{r.created_machine | state: :stopped, storage_gb: 3}
    assert {:error, %{category: :identity_conflict}} = advance(a, s, unknown, {:resolve, partial})

    assert {:error, _} =
             a.machine(s, :resolve, [
               ManagedMachine.key(unknown),
               Contract.guard(unknown),
               r.observed_machine,
               1200
             ])

    assert {:error, _} =
             a.machine(s, :request, [ManagedMachine.key(unknown), :delete, unknown.version, 1200])

    assert {:error, _} = advance(a, s, sent, {:complete, %{partial | overlay_gb: 2}})
    assert {:ok, %{disk_gb: 5}} = a.usage(s, "worker")
    assert {:ok, deleted} = advance(a, s, unknown, {:resolve, :absent})
    assert deleted.state == :deleted and deleted.disk_expansions["grow"].state == :deleted
    assert {:ok, %{disk_gb: 0}} = a.usage(s, "worker")
    assert {:ok, ^deleted} = accept(a, s, r)
  end

  def race(a, s) do
    first = stopped(a, s, "first")
    second = stopped(a, s, "second")
    capacity = %{Contract.capacity(20) | disk_gb: 7}

    results =
      [first, second]
      |> Enum.map(fn m ->
        Task.async(fn -> accept(a, s, m, "grow", %{storage_gb: 4}, capacity) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{category: :admission_exhausted}}, &1)) == 1
    assert {:ok, %{disk_gb: 7}} = a.usage(s, "worker")
  end
end
