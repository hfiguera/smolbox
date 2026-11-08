defmodule SmolBox.Store.NativeSourceCodecTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.Embedded.{Config, CreationFeatures, Identity, NativeSource, Request}
  alias SmolBox.Runtime.{NativeSupport, Target}
  alias SmolBox.Store.{Codec, CodecNativeSources, MachineOps, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  alias SmolBox.{
    Execution,
    ExecutionSpec,
    ImagePull,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    NetworkPolicy,
    Profile,
    Source
  }

  defp fixture(architecture, kind \\ :oci) do
    options = [
      id: "approved-oci",
      reference: "registry.example/team/app@sha256:" <> String.duplicate("a", 64),
      architecture: architecture
    ]

    {:ok, source} =
      if kind == :registry,
        do:
          Source.registry(
            options ++ [content_sha256: String.duplicate("b", 64), credential_ref: "tenant-read"]
          ),
        else: Source.oci(options)

    {:ok, network} = NetworkPolicy.new(hosts: ["registry.example"])
    {:ok, profile} = Profile.new("oci", network: network)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "native-source",
        id: "machine",
        artifact: Source.artifact(source),
        profile: profile
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)

    assignment = %Assignment{
      version: 2,
      binding: %Binding{
        kind: :embedded,
        target_id: "worker",
        generation: String.duplicate("d", 32)
      },
      creation:
        CreationFeatures.attach(
          %{
            "name" => "owned-source",
            "owner_token" => String.duplicate("b", 64),
            "incarnation" => String.duplicate("c", 32),
            "source" => Source.artifact(source),
            "resources" => %{
              "cpus" => profile.cpus,
              "memory_mib" => profile.memory_mb,
              "storage_gib" => profile.storage_gb,
              "overlay_gib" => profile.overlay_gb
            },
            "labels" => %{}
          },
          CreationFeatures.from_spec(spec)
        )
    }

    {source, record, assignment}
  end

  defp reserved(kind \\ :oci) do
    {source, record, assignment} = fixture("x86_64", kind)

    record = %{
      record
      | backend_assignment: assignment,
        worker_id: "worker",
        worker_generation: 1,
        machine_name: "owned-source",
        reservation: Profile.resources(record.spec.profile),
        state: :creating,
        phase: :dispatching
    }

    {source, record}
  end

  defp observed(record, state, pid) do
    create = record.backend_assignment.creation

    receipt = %{
      "target_id" => "worker",
      "domain_generation" => record.backend_assignment.binding.generation,
      "name" => record.machine_name,
      "owner_token" => create["owner_token"],
      "incarnation" => create["incarnation"],
      "material_sha256" => String.duplicate("e", 64),
      "material" => %{
        "schema" => 2,
        "revision" => 0,
        "record_sha256" => String.duplicate("e", 64),
        "chain_sha256" => String.duplicate("f", 64),
        "operation_id" => nil,
        "request_sha256" => nil
      }
    }

    profile = record.spec.profile

    %Machine{
      name: record.machine_name,
      state: state,
      created_at: nil,
      cpus: profile.cpus,
      memory_mb: profile.memory_mb,
      storage_gb: profile.storage_gb,
      overlay_gb: profile.overlay_gb,
      network: profile.network,
      backend_identity: %Identity{receipt: receipt, pid_identity: pid}
    }
  end

  test "native pre-dispatch rejections retain operation names accepted by the store" do
    budget = %SmolBox.Backend.Budget{
      timeout_ms: 1000,
      max_request_bytes: 1024,
      max_response_bytes: 1024
    }

    for {internal, persisted} <- [inspect_machine: :inspect, create_prepared: :create] do
      assert {:error, error} = SmolBox.Backend.EmbeddedOperation.build(%{}, internal, [], budget)
      assert error.operation == persisted and error.evidence == :not_dispatched
      assert SmolBox.ExecutionValidation.error?(error)
    end
  end

  test "native registry preparation survives the prepared transition and codec round trip" do
    {source, record} = reserved(:registry)
    record = %{record | phase: :preparing}

    for cached <- [false, true] do
      assert {:ok, prepared} =
               SmolBox.ArtifactPreparation.from_wire(source, %{
                 "digest" => "sha256:" <> source.content_sha256,
                 "sizeBytes" => 14_952_849,
                 "alreadyCached" => cached
               })

      assert {:ok, saved} =
               ManagedMachine.transition(
                 record,
                 [preparation: prepared, phase: :prepared],
                 record.updated_at_ms + 1
               )

      assert Assignment.record_valid?(saved)
      assert {:ok, <<"smolbox-record-v19\0", _::binary>> = bytes} = Codec.encode(saved)
      assert {:ok, ^saved} = Codec.decode(bytes)

      for crossed <- [
            %{prepared | content_sha256: String.duplicate("e", 64)},
            %{prepared | manifest_sha256: String.duplicate("f", 64)},
            %{prepared | reference: "registry.example/foreign@sha256:" <> source.sha256}
          ] do
        refute Assignment.record_valid?(%{saved | preparation: crossed})
        assert {:error, _} = Codec.encode(%{saved | preparation: crossed})
      end

      {_oci, oci_record} = reserved()
      refute Assignment.record_valid?(%{oci_record | preparation: prepared})
    end
  end

  test "typed source identity is selective v19 data and cannot enter old native envelopes" do
    {_source, record} = reserved()
    assert Assignment.valid?(record.backend_assignment)
    assert :ok = ManagedMachine.validate(record)
    assert CodecNativeSources.required?(record)
    assert {:ok, <<"smolbox-record-v19\0", payload::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for version <- 1..18,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

    assert {:error, _} = Codec.decode(bytes <> "trailing")

    assert {:error, _} =
             Codec.decode("smolbox-record-v19\0" <> :erlang.term_to_binary(record, compressed: 9))

    assert {:error, _} =
             Codec.encode(%{
               record
               | backend_assignment: %{record.backend_assignment | version: 1}
             })

    refute Request.valid?(
             %{"operation" => "create", "create" => record.backend_assignment.creation},
             1000,
             2
           )
  end

  test "source substitution, invented credentials and mixed local authority reject" do
    {_source, record} = reserved()
    creation = record.backend_assignment.creation

    for changed <- [
          put_in(creation["source"]["sha256"], String.duplicate("0", 64)),
          put_in(creation["source"]["reference"], "registry.example/team/app:latest"),
          put_in(creation["source"]["architecture"], "aarch64"),
          put_in(creation["source"]["credential_ref"], "invented"),
          Map.put(creation, "artifact", %{}),
          Map.put(creation, "metadata", %{})
        ] do
      altered = %{record | backend_assignment: %{record.backend_assignment | creation: changed}}
      assert {:error, _} = Codec.encode(altered)
    end

    changed = put_in(creation["source"]["id"], "different-alias")
    assert NativeSource.creation?(changed)
    refute NativeSource.matches?(changed, record.spec.artifact)

    assert {:error, _} =
             Codec.encode(%{
               record
               | backend_assignment: %{record.backend_assignment | creation: changed}
             })

    local =
      creation
      |> Map.delete("source")
      |> Map.put("artifact", %{
        "path" => "/approved/local.smolmachine",
        "sha256" => record.spec.artifact["sha256"],
        "max_bytes" => 1024,
        "guest_platform" => "linux/amd64"
      })

    disguised = %{record | backend_assignment: %{record.backend_assignment | creation: local}}
    assert Assignment.valid?(disguised.backend_assignment)
    assert {:error, _} = Codec.encode(disguised)
  end

  test "registry creation preserves manifest blob and credential reference in selective v19" do
    {_oci, record} = reserved()

    {:ok, source} =
      Source.registry(
        id: "approved-registry",
        reference: "registry.example/team/pack@sha256:" <> String.duplicate("a", 64),
        content_sha256: String.duplicate("b", 64),
        architecture: "x86_64",
        credential_ref: "tenant-read"
      )

    artifact = Source.artifact(source)

    record = %{
      record
      | spec: %{record.spec | artifact: artifact},
        backend_assignment: %{
          record.backend_assignment
          | creation: Map.put(record.backend_assignment.creation, "source", artifact)
        }
    }

    assert NativeSource.registry_creation?(record.backend_assignment.creation)
    refute NativeSource.creation?(record.backend_assignment.creation)
    assert NativeSource.matches?(record.backend_assignment.creation, artifact)
    assert Assignment.valid?(record.backend_assignment)
    assert :ok = ManagedMachine.validate(record)
    assert {:ok, <<"smolbox-record-v19\0", payload::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for version <- 16..18,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

    for changed <- [
          Map.put(artifact, "identity_token", "private"),
          Map.put(artifact, "content_sha256", String.duplicate("c", 64)),
          Map.put(artifact, "credential_ref", "different")
        ] do
      altered = %{
        record
        | backend_assignment: %{
            record.backend_assignment
            | creation: Map.put(record.backend_assignment.creation, "source", changed)
          }
      }

      assert {:error, _} = Codec.encode(altered)
    end

    refute Request.valid?(
             %{"operation" => "create_oci", "create" => record.backend_assignment.creation},
             1000,
             2
           )

    assert {:error, _} =
             Codec.encode(%{
               record
               | backend_assignment: %{record.backend_assignment | version: 1}
             })
  end

  test "retained image pull inherits source authority and reservations without becoming launch or exit" do
    {source, record} = reserved()

    machine = %{
      record
      | state: :running,
        phase: nil,
        operation: nil,
        created_machine: observed(record, :created, nil),
        observed_machine: observed(record, :running, [100, 12_345])
    }

    {:ok, another} =
      Source.oci(
        id: "another-approved-image",
        reference: "registry.example/team/other@sha256:" <> String.duplicate("0", 64),
        architecture: source.architecture
      )

    {:ok, pull} = ImagePull.new(another)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: machine.scope,
        id: "pull",
        artifact: machine.spec.artifact,
        profile: machine.spec.profile,
        command: pull
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, execution} = Execution.new(spec, fingerprint, 1000)
    assert {:ok, attached, execution} = MachineOps.attach(machine, execution, 1000)
    assert attached.reservation == machine.reservation
    assert execution.reservation == nil
    assert execution.backend_assignment == machine.backend_assignment
    assert execution.backend_assignment.creation["source"] == Source.artifact(source)
    assert execution.spec.command.source == another
    assert :ok = Execution.validate(execution)
    assert {:ok, <<"smolbox-record-v19\0", _::binary>> = bytes} = Codec.encode(execution)
    assert {:ok, ^execution} = Codec.decode(bytes)
    assert {:error, _} = Execution.transition(execution, [backend_assignment: nil], 1000)

    sdk =
      SmolBox.Embedded.SDKIdentity.implemented(
        "1.22.0",
        "9f446ae00219148ca4a703914f44a8e2fab11655"
      )
      |> put_in(["feature_versions", "remote_sources"], 1)
      |> put_in(["feature_versions", "images"], 1)

    native = Package.create(protocol_major: 2, platform: :linux, sdk_identity: sdk)
    on_exit(fn -> File.rm_rf!(native.package_path) end)

    native = %{
      native
      | id: "worker",
        domain_generation: record.backend_assignment.binding.generation,
        sources: [source, another],
        artifacts: [],
        profiles: [record.spec.profile]
    }

    assert :ok = Config.validate(native)
    {:ok, context} = SmolBox.Backend.EmbeddedContext.new(native, self())
    {:ok, context} = SmolBox.Backend.EmbeddedContext.assign(context, execution)
    assert context.managed_machine == ManagedMachine.key(machine)

    assert {:ok, request, _, <<>>, nil} =
             SmolBox.Backend.EmbeddedOperation.build(
               context,
               :pull_image,
               [machine.machine_name, another],
               native.budget
             )

    assert request["receipt"] == execution.created_machine.backend_identity.receipt
    assert request["source"] == SmolBox.Embedded.ImageContract.source(another)

    assert {:error, _} =
             SmolBox.Backend.EmbeddedOperation.build(
               context,
               :pull_image,
               [machine.machine_name, source],
               native.budget
             )

    exercise_runtime_pull(execution, another)
  end

  defmodule PullClock do
    def now, do: 1000
    def monotonic, do: 1000
  end

  defmodule PullStore do
    def claim(store, _key, _owner, _now, _lease), do: {:ok, Agent.get(store, & &1)}

    def write(store, _key, _guard, changes, now) do
      Agent.get_and_update(store, fn record ->
        {:ok, next} = Execution.transition(record, changes, now)
        {{:ok, next}, next}
      end)
    end
  end

  defmodule PullAdapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :pull_image
    def assign(context, record), do: {:ok, Map.put(context, :record, record)}

    def invoke(%{record: %Execution{} = record} = context, :pull_image, [name, source], _budget) do
      send(context.observer, {:assigned_pull, context.owner, record, name, source})

      SmolBox.Image.from_wire(%{
        "reference" => source.reference,
        "digest" => "sha256:" <> String.duplicate("b", 64),
        "size" => 123,
        "architecture" => "amd64",
        "os" => "linux",
        "layerCount" => 2
      })
    end

    def invoke(_, _, _, _),
      do: {:error, %SmolBox.Error{category: :identity_conflict, operation: :pull_image}}
  end

  defp exercise_runtime_pull(execution, source) do
    execution = %{
      execution
      | state: :dispatching,
        evidence: :dispatch_uncertain,
        deadlines: Map.put(execution.deadlines, :execution, 5000)
    }

    assert :ok = Execution.validate(execution)
    store = start_supervised!({Agent, fn -> execution end})

    reference = %SmolBox.Backend.Reference{
      kind: :embedded,
      id: execution.worker_id,
      adapter: PullAdapter,
      context: %{observer: self(), owner: :pinned_original},
      budget: %SmolBox.Backend.Budget{
        timeout_ms: 1000,
        max_request_bytes: 4096,
        max_response_bytes: 8192
      }
    }

    session = %SmolBox.Runtime.Session{
      config: %{
        store: {PullStore, store},
        owner: "owner",
        clock: PullClock,
        poll_ms: 20,
        lease_ms: 1000
      },
      key: Execution.key(execution),
      worker: %Target{kind: :embedded, id: execution.worker_id, connection: reference},
      wall: 1000,
      monotonic: 1000
    }

    assert {:ok, %{state: :completed, evidence: :image_pulled, result: %SmolBox.Image{}}} =
             SmolBox.Runtime.ImageObservation.run(session, execution)

    name = execution.machine_name
    assert_received {:assigned_pull, :pinned_original, ^execution, ^name, ^source}
  end

  for kind <- [:oci, :registry] do
    test "Memory atomically retains #{kind} intent with capacity and paged recovery" do
      {_source, record, assignment} = fixture("x86_64", unquote(kind))
      store = start_supervised!(Memory)
      key = ManagedMachine.key(record)
      assert {:ok, %{native_sources: 1, registry_sources: 1}} = Memory.capabilities(store)
      assert {:ok, _} = Memory.bind_backend(store, "worker", assignment.binding)
      assert {:ok, _} = Memory.claim_worker(store, "worker", "owner", 1000, 10_000)
      assert {:ok, _} = Memory.machine(store, :accept, [record, 10])
      assert {:ok, claimed} = Memory.machine(store, :claim, [key, "owner", 1000, 10_000])

      guard = %{
        owner: claimed.claim_owner,
        generation: claimed.generation,
        version: claimed.version
      }

      capacity = Profile.resources(record.spec.profile)
      altered = put_in(assignment.creation["source"]["id"], "other-source")
      assert Assignment.valid?(altered)

      assert {:error, _} =
               Memory.machine(store, :reserve, [
                 key,
                 guard,
                 {"worker", "owned-source", capacity, altered},
                 1000
               ])

      empty = Map.new(capacity, fn {key, _value} -> {key, 0} end)
      assert {:ok, ^empty} = Memory.usage(store, "worker")
      assert {:ok, ^claimed} = Memory.machine(store, :fetch, [key])

      assert {:ok, saved} =
               Memory.machine(store, :reserve, [
                 key,
                 guard,
                 {"worker", "owned-source", capacity, assignment},
                 1000
               ])

      assert saved.backend_assignment == assignment
      assert {:ok, ^capacity} = Memory.usage(store, "worker")
      assert {:ok, [^saved], nil} = Memory.backend_assignments(store, "worker", nil, 10)
      assert {:ok, bytes} = Codec.encode(saved)
      assert {:ok, ^saved} = Codec.decode(bytes)
    end
  end

  test "current approved helpers reject source admission despite structural reader support" do
    config = Package.create(protocol_major: 2)
    {source, record, assignment} = fixture(config.architecture)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    config = %{config | sources: [source], profiles: [record.spec.profile]}
    assert :ok = Config.validate(config)
    refute Assignment.supports?(config, record.spec)
    refute Assignment.approved?(assignment, config, record.spec)
    assert {:error, _} = Assignment.new(config, record.spec, "owned-source")
  end

  for kind <- [:oci, :registry] do
    test "fresh BEAM loads fixed #{kind} vocabulary before safe v19 decoding" do
      {_source, record} = reserved(unquote(kind))
      assert {:ok, bytes} = Codec.encode(record)

      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-native-source-" <> Base.encode16(:crypto.strong_rand_bytes(16))
        )

      on_exit(fn -> File.rm(path) end)
      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code = ~S"""
      [path] = System.argv()
      case path |> File.read!() |> SmolBox.Store.Codec.decode() do
        {:ok, %{backend_assignment: %{version: 2, creation: %{"source" => %{"kind" => kind}}}}} when kind in ["oci","registry"] -> IO.puts("fresh-source")
        _ -> System.halt(1)
      end
      """

      assert {"fresh-source\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end

  defmodule ReaderStore do
    def capabilities({store, omitted}) do
      {:ok, caps} = Memory.capabilities(store)
      {:ok, Map.drop(caps, omitted)}
    end

    def bind_backend(_store, _worker, _binding), do: raise("reader check must not enroll")

    def backend_assignments(_store, _worker, _cursor, _limit),
      do: raise("reader check must not recover")

    def machine(_store, _operation, _arguments), do: raise("reader check must not mutate")
  end

  test "future source descriptors require reader and atomic source/image markers before enrollment" do
    store = start_supervised!(Memory)
    config = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    # Exercise the reader gate independently. This descriptor remains rejected
    # by Config/package approval and cannot actually start a helper.
    sdk = put_in(Config.sdk_identity(config)["feature_versions"]["remote_sources"], 1)
    sdk = put_in(sdk["feature_versions"]["images"], 1)
    config = %{config | sdk_identity: sdk}
    assert {:error, _} = Config.validate(config)
    target = %Target{kind: :embedded, native_config: config}

    for missing <- [[:native_sources], [:registry_sources], [:managed_images]] do
      assert {:error, %{category: :unsupported_capability}} =
               NativeSupport.verify(%{workers: [target], store: {ReaderStore, {store, missing}}})
    end

    assert :ok = NativeSupport.verify(%{workers: [target], store: {Memory, store}})
    assert :ok = NativeSupport.verify(%{workers: [target], store: {ReaderStore, {store, []}}})
  end
end
