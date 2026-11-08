defmodule SmolBox.NativeMountIntentTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.Embedded.{Identity, JSON, MountContract, NativeSource, Request, VolumeAttachment}

  alias SmolBox.{
    Command,
    Execution,
    ExecutionSpec,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    Profile,
    VolumeMount
  }

  alias SmolBox.Store.{Codec, MachineOps}

  defp fixture do
    {:ok, fixture} =
      File.read!("native/smolbox-protocol/fixtures/mounted-creation-request.json")
      |> JSON.decode()

    fixture
  end

  defp assignment do
    create = fixture()["operation"]["create"]
    backing = hd(create["volume_mounts"])["proof"]["backing"]

    %Assignment{
      version: 2,
      creation: create,
      binding: %Binding{
        kind: :embedded,
        target_id: backing["target_id"],
        generation: backing["domain_generation"]
      }
    }
  end

  defp machine do
    assignment = assignment()
    {:ok, profile} = Profile.new("mounted", memory_mb: 256)
    {:ok, ref} = VolumeMount.new("data", "/mnt/volumes/data")

    artifact = %{
      "id" => "approved",
      "sha256" => assignment.creation["artifact"]["sha256"],
      "architecture" => "x86_64"
    }

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "mounted",
        id: "machine",
        artifact: artifact,
        profile: profile,
        volumes: [ref]
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, machine} = ManagedMachine.new(spec, fingerprint, 1000)
    mount = hd(assignment.creation["volume_mounts"])

    attachment = %VolumeAttachment{
      binding: assignment.binding,
      volume_key: {spec.scope, "data"},
      proof: mount["proof"],
      target: ref.target,
      readonly: false
    }

    {:ok, created} = JSON.decode(File.read!("native/smolbox-protocol/fixtures/created-v2.json"))

    receipt =
      created["outcome"]["receipt"]
      |> Map.merge(%{
        "target_id" => assignment.binding.target_id,
        "domain_generation" => assignment.binding.generation,
        "name" => assignment.creation["name"],
        "owner_token" => assignment.creation["owner_token"],
        "incarnation" => assignment.creation["incarnation"]
      })

    observed = %Machine{
      name: assignment.creation["name"],
      state: :running,
      created_at: nil,
      cpus: 1,
      memory_mb: 256,
      storage_gb: 1,
      overlay_gb: 1,
      backend_identity: %Identity{
        receipt: receipt,
        pid_identity: [123, 456]
      },
      mounts: MountContract.paths(assignment.creation)
    }

    %{
      machine
      | backend_assignment: assignment,
        worker_id: assignment.binding.target_id,
        worker_generation: 1,
        machine_name: assignment.creation["name"],
        volume_worker_id: assignment.binding.target_id,
        native_mounts: [attachment],
        mounts: observed.mounts,
        reservation: Profile.resources(profile),
        created_machine: observed,
        observed_machine: observed,
        state: :running,
        operation: nil,
        phase: nil
    }
  end

  test "shared mounted creation fixture preserves proof, bounds, paths and exact domain" do
    operation = fixture()["operation"]
    assert Request.valid?(operation, 1000, 2)
    refute Request.valid?(operation, 1000, 1)
    assert Assignment.valid?(assignment())
    assert MountContract.bound?(operation["create"]["volume_mounts"], assignment().binding)

    assert hd(MountContract.paths(operation["create"])).source ==
             "/srv/smolvm/volumes/sbv-" <> String.duplicate("a", 32)

    for value <- [
          nil,
          [],
          [Map.put(hd(operation["create"]["volume_mounts"]), "source", "/caller")]
        ] do
      refute Request.valid?(put_in(operation["create"]["volume_mounts"], value), 1000, 2)
    end

    refute MountContract.creation_keys?(nil, [], 2)

    refute Assignment.valid?(
             put_in(
               assignment(),
               [
                 Access.key(:creation),
                 "volume_mounts",
                 Access.at(0),
                 "proof",
                 "backing",
                 "domain_generation"
               ],
               String.duplicate("f", 32)
             )
           )
  end

  test "local registry and OCI creation share exact mount schema without source substitution" do
    create = assignment().creation

    source = %{
      "kind" => "oci",
      "id" => "approved",
      "sha256" => String.duplicate("d", 64),
      "architecture" => "x86_64",
      "reference" => "registry.example/app@sha256:" <> String.duplicate("d", 64)
    }

    oci = create |> Map.delete("artifact") |> Map.put("source", source)
    assert NativeSource.creation?(oci)

    registry =
      put_in(
        oci["source"],
        Map.merge(source, %{"kind" => "registry", "content_sha256" => String.duplicate("e", 64)})
      )

    assert NativeSource.registry_creation?(registry)
    refute NativeSource.creation?(registry)
    refute NativeSource.registry_creation?(Map.put(registry, "volume_mounts", nil))
  end

  test "assigned machine proof must match durable attachment and actual observed mounts" do
    machine = machine()
    assert :ok = ManagedMachine.validate(machine)
    assert {:ok, <<"smolbox-record-v21\0", _::binary>> = bytes} = Codec.encode(machine)
    assert {:ok, ^machine} = Codec.decode(bytes)

    shifted =
      put_in(
        machine,
        [
          Access.key(:backend_assignment),
          Access.key(:creation),
          "volume_mounts",
          Access.at(0),
          "proof",
          "backing",
          "inode"
        ],
        7
      )

    assert {:error, _} = ManagedMachine.validate(shifted)

    assert {:error, _} =
             ManagedMachine.validate(%{
               machine
               | observed_machine: %{machine.observed_machine | mounts: []}
             })

    assert {:error, _} =
             ManagedMachine.validate(%{
               machine
               | backend_assignment: %{
                   machine.backend_assignment
                   | creation: Map.delete(machine.backend_assignment.creation, "volume_mounts")
                 }
             })
  end

  test "retained command inherits mounted assignment and selectively uses v21" do
    machine = machine()
    {:ok, command} = Command.new(["true"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: machine.scope,
        id: "command",
        artifact: machine.spec.artifact,
        profile: machine.spec.profile,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, execution} = Execution.new(spec, fingerprint, 1000)
    assert {:ok, _, attached} = MachineOps.attach(machine, execution, 1100)
    assert attached.backend_assignment == machine.backend_assignment
    assert attached.created_machine.mounts == machine.mounts
    assert :ok = Execution.validate(attached)
    assert {:ok, <<"smolbox-record-v21\0", payload::binary>> = bytes} = Codec.encode(attached)
    assert {:ok, ^attached} = Codec.decode(bytes)

    for version <- 16..20,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))
  end

  test "observed mount configuration is actual, bounded and matched to assigned authority" do
    alias SmolBox.Backend.{EmbeddedContext, EmbeddedReply}
    alias SmolBox.Embedded.{CreationFeatures, Protocol}

    {:ok, outcome} =
      JSON.decode(File.read!("native/smolbox-protocol/fixtures/mounted-observation-v2.json"))

    assert Protocol.valid_outcome?(outcome, 2)
    refute Protocol.valid_outcome?(outcome, 1)
    assert CreationFeatures.configuration?(outcome["observation"]["configuration"])
    machine = machine()

    context = %EmbeddedContext{
      config: nil,
      server: self(),
      assignment: machine.backend_assignment,
      identity: machine.created_machine.backend_identity,
      profile: machine.spec.profile,
      spec: machine.spec,
      name: machine.machine_name
    }

    empty = %{stdout: <<>>, stderr: <<>>, file: <<>>}

    assert {:ok, observed} =
             EmbeddedReply.decode(context, :inspect_machine, %{}, {:ok, outcome, empty, nil})

    assert observed.mounts == machine.mounts

    for field <- ["source", "target", "readonly"] do
      value =
        case field do
          "source" -> "/foreign"
          "target" -> "/mnt/volumes/other"
          "readonly" -> true
        end

      changed =
        put_in(outcome, ["observation", "configuration", "mounts", Access.at(0), field], value)

      assert Protocol.valid_outcome?(changed, 2)

      assert {:error, _} =
               EmbeddedReply.decode(context, :inspect_machine, %{}, {:ok, changed, empty, nil})
    end

    missing = update_in(outcome["observation"]["configuration"], &Map.delete(&1, "mounts"))
    assert Protocol.valid_outcome?(missing, 2)

    assert {:error, _} =
             EmbeddedReply.decode(context, :inspect_machine, %{}, {:ok, missing, empty, nil})

    unmounted = %{
      context
      | assignment: %{
          context.assignment
          | creation: Map.delete(context.assignment.creation, "volume_mounts")
        }
    }

    assert {:error, _} =
             EmbeddedReply.decode(unmounted, :inspect_machine, %{}, {:ok, outcome, empty, nil})

    for mounts <- [
          nil,
          [],
          List.duplicate(hd(outcome["observation"]["configuration"]["mounts"]), 9)
        ] do
      refute Protocol.valid_outcome?(
               put_in(outcome["observation"]["configuration"]["mounts"], mounts),
               2
             )
    end

    staged =
      put_in(outcome, ["observation", "configuration", "mounts", Access.at(0), "staged"], true)

    refute Protocol.valid_outcome?(staged, 2)
  end
end
