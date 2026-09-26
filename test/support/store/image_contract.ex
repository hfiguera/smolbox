defmodule SmolBox.Store.ImageContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Execution, ExecutionSpec, Image, ImagePull, Source}
  alias SmolBox.Store.{Contract, MachineContract}

  def pull(adapter, store) do
    assert {:ok, %{managed_images: 1}} = adapter.capabilities(store)
    {:ok, network} = SmolBox.NetworkPolicy.new(hosts: ["registry.example.com"])
    profile = %{Contract.record().spec.profile | network: network}

    {:ok, source} =
      Source.oci(
        id: "image",
        reference: "registry.example.com/team/app@sha256:" <> String.duplicate("a", 64),
        architecture: "x86_64"
      )

    {:ok, pull} = ImagePull.new(source)
    machine = MachineContract.running(adapter, store, [], profile, Source.artifact(source))
    machine_key = {machine.scope, machine.id}

    spec = %{
      Contract.record().spec
      | command: pull,
        profile: profile,
        artifact: machine.spec.artifact
    }

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, initial} = Execution.new(spec, fingerprint, 1000)
    key = Execution.key(initial)
    assert {:ok, accepted} = adapter.machine(store, :submit, [machine_key, initial, 10, 1000])
    assert {:ok, ^accepted} = adapter.machine(store, :submit, [machine_key, initial, 10, 1000])
    assert {:ok, ^accepted} = adapter.fetch(store, key)

    assert {:ok, %{active_execution: ^key} = busy} = adapter.machine(store, :fetch, [machine_key])

    assert {:error, %{category: :admission_exhausted}} =
             adapter.machine(store, :request, [machine_key, :stop, busy.version, 1000])

    record =
      Enum.reduce(
        [
          [state: :preparing],
          [state: :ready],
          [state: :dispatching, evidence: :dispatch_uncertain]
        ],
        accepted,
        fn changes, _record ->
          {:ok, claimed} = adapter.claim(store, key, "owner", 1000, 5000)

          assert {:ok, written} =
                   adapter.write(store, key, Contract.guard(claimed), changes, 1000)

          written
        end
      )

    image = %Image{
      reference: source.reference,
      digest: "sha256:" <> String.duplicate("b", 64),
      digest_kind: :configuration,
      size_bytes: 4096,
      architecture: "amd64",
      os: "linux",
      layer_count: 1
    }

    assert {:ok, completed} =
             adapter.write(
               store,
               key,
               Contract.guard(record),
               [state: :completed, evidence: :image_pulled, result: image, collection: :complete],
               1000
             )

    assert {:ok, ^completed} = adapter.fetch(store, key)

    assert {:ok, %{cleanup: :complete}} =
             adapter.machine(store, :finish, [key, Contract.guard(completed), 1000])

    assert {:ok, %{active_execution: nil, spec: original}} =
             adapter.machine(store, :fetch, [machine_key])

    assert original == machine.spec
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
  end
end
