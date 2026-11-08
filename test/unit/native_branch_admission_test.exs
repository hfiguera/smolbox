defmodule SmolBox.NativeBranchAdmissionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branch, BranchPolicy, BranchSpec, ManagedMachine, ManagedMachineSpec, Profile}
  alias SmolBox.Store.{BranchOps, MachineContract}

  @fixture Path.expand("../../native/smolbox-protocol/fixtures/branch-admission-v1.json", __DIR__)
  @external_resource @fixture
  @cases Jason.decode!(File.read!(@fixture))

  test "shared native plans match actual public branch admission and exact additional capacity" do
    for row <- @cases do
      options =
        for key <- [:cpus, :memory_mb, :storage_gb, :overlay_gb, :host_overhead_mb],
            do: {key, row[Atom.to_string(key)]}

      profile = Profile.new("branch-source", options)
      extra = resources(row["extra"])
      policy = BranchPolicy.new(id: "branches", resources: extra)

      case {profile, policy, row["expected"]} do
        {{:ok, profile}, {:ok, policy}, expected} ->
          source = source(profile)
          {:ok, request} = BranchSpec.new(id: "child", policy: policy, idle: true)
          usage = Profile.resources(profile)
          total = Map.merge(usage, extra, fn _, a, b -> a + b end)
          capacity = Map.merge(usage, total, fn _, a, b -> a + b end)

          result =
            BranchOps.accept(
              source,
              request,
              String.duplicate("f", 64),
              "owned-child",
              capacity,
              usage,
              1100
            )

          if expected do
            assert total == resources(expected["total_additional"])
            assert {:ok, parent, child} = result
            assert child.reservation == resources(expected["ordinary_child"])
            assert Branch.resources(child) == extra
            assert parent.reservation == source.reservation
            assert parent.active_branch == child.id

            for key <- [:slots, :cpus, :memory_mb, :disk_gb] do
              short = Map.update!(capacity, key, &(&1 - 1))

              assert {:error, _} =
                       BranchOps.accept(
                         source,
                         request,
                         String.duplicate("f", 64),
                         "owned-child",
                         short,
                         usage,
                         1100
                       )
            end
          else
            assert {:error, _} = result
          end

        {_profile, _policy, nil} ->
          :ok
      end
    end
  end

  defp resources(value),
    do:
      Map.new([:slots, :cpus, :memory_mb, :disk_gb], &{&1, Map.fetch!(value, Atom.to_string(&1))})

  defp source(profile) do
    base = MachineContract.record("source")
    spec = %{base.spec | profile: profile, checkpointable: true}
    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, source} = ManagedMachine.new(spec, fingerprint, 1000)

    machine = %SmolBox.Machine{
      name: "owned-source",
      state: :running,
      created_at: 1000,
      cpus: profile.cpus,
      memory_mb: profile.memory_mb,
      storage_gb: profile.storage_gb,
      overlay_gb: profile.overlay_gb,
      network: :offline,
      ports: []
    }

    {:ok, source} =
      ManagedMachine.update(
        source,
        %{
          state: :running,
          operation: nil,
          phase: nil,
          worker_id: "worker",
          worker_generation: 1,
          machine_name: machine.name,
          reservation: Profile.resources(profile),
          created_machine: machine,
          observed_machine: machine
        },
        1000
      )

    source
  end
end
