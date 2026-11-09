defmodule SmolBox.NativeGrowthHistoryTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.Backend.{EmbeddedContext, EmbeddedGrowthObservation, EmbeddedReply}

  alias SmolBox.Embedded.{
    Config,
    CreationFeatures,
    GrowthTransition,
    HistoricalExecution,
    Identity,
    NativeGrowth
  }

  alias SmolBox.Runtime.Config, as: RuntimeConfig
  alias SmolBox.Runtime.{DiskExpansions, NativeRecovery, Target}
  alias SmolBox.Store.{Codec, ExpansionOps, MachineOps, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  alias SmolBox.{
    ArtifactPreparation,
    Command,
    DiskExpansion,
    Execution,
    ExecutionSpec,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    NetworkPolicy,
    Profile,
    Source
  }

  defmodule QualificationPeer do
    def supports_operation?(_context, operation),
      do: operation in [:qualify_growth, :inspect_machine]

    def assign(context, record), do: {:ok, Map.put(context, :record, record)}

    def invoke(context, :qualify_growth, [true], budget) do
      send(context.observer, {:qualified, context.record, budget.timeout_ms})
      Process.sleep(10)
      {:ok, context.grown}
    end

    def invoke(context, :inspect_machine, [_name], budget) do
      send(context.observer, {:inspected, context.record, budget.timeout_ms})
      {:ok, context.grown}
    end
  end

  defp fixture(kind \\ :local) do
    [first, second] =
      "../../native/smolbox-protocol/fixtures/growth-transitions-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn wire ->
        {:ok, proof} = GrowthTransition.from_wire(wire)
        proof
      end)

    {artifact, network, preparation} = fixture_source(kind)
    {:ok, profile} = Profile.new("growth", network: network)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "native-growth",
        id: "vm",
        artifact: artifact,
        profile: profile
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)
    receipt = first.previous

    created = %Machine{
      name: receipt["name"],
      state: :stopped,
      created_at: nil,
      cpus: profile.cpus,
      memory_mb: profile.memory_mb,
      storage_gb: 1,
      overlay_gb: 1,
      network: profile.network,
      backend_identity: %Identity{receipt: receipt}
    }

    assignment = %Assignment{
      version: 2,
      binding: %Binding{
        kind: :embedded,
        target_id: receipt["target_id"],
        generation: receipt["domain_generation"]
      },
      creation:
        %{
          "name" => receipt["name"],
          "owner_token" => receipt["owner_token"],
          "incarnation" => receipt["incarnation"],
          "resources" => %{
            "cpus" => profile.cpus,
            "memory_mib" => profile.memory_mb,
            "storage_gib" => 1,
            "overlay_gib" => 1
          },
          "labels" => %{}
        }
        |> Map.put(
          if(kind == :local, do: "artifact", else: "source"),
          if(kind == :local,
            do: %{
              "path" => "/fixture.smolmachine",
              "sha256" => artifact["sha256"],
              "max_bytes" => 1024,
              "guest_platform" => "linux/arm64"
            },
            else: artifact
          )
        )
        |> CreationFeatures.attach(CreationFeatures.from_spec(spec))
    }

    record = %{
      record
      | backend_assignment: assignment,
        worker_id: receipt["target_id"],
        worker_generation: 1,
        machine_name: receipt["name"],
        reservation: Profile.resources(profile),
        state: :stopped,
        preparation: preparation,
        operation: nil,
        phase: nil,
        created_machine: created,
        observed_machine: created
    }

    assert :ok = ManagedMachine.validate(record)
    {record, first, second}
  end

  defp fixture_source(:local),
    do:
      {%{
         "id" => "fixture",
         "sha256" => String.duplicate("d", 64),
         "architecture" => "aarch64"
       }, :offline, nil}

  # These canonical protocol proofs exercise client-side source/history
  # composition, without attesting an SDK source configuration or launching it.
  defp fixture_source(kind) when kind in [:oci, :registry] do
    options = [
      id: "fixture",
      reference: "registry.example/team/app@sha256:" <> String.duplicate("a", 64),
      architecture: "aarch64"
    ]

    if kind == :oci do
      {:ok, source} = Source.oci(options)
      {:ok, network} = NetworkPolicy.new(hosts: ["registry.example"])
      {Source.artifact(source), network, nil}
    else
      {:ok, source} =
        Source.registry(
          options ++ [content_sha256: String.duplicate("b", 64), credential_ref: "read"]
        )

      {:ok, prepared} =
        ArtifactPreparation.from_wire(source, %{
          "digest" => "sha256:" <> source.content_sha256,
          "sizeBytes" => 123,
          "alreadyCached" => false
        })

      {Source.artifact(source), :offline, prepared}
    end
  end

  defp accept(record, transition, now) do
    targets =
      transition.change["request"]
      |> Enum.reject(fn {_, v} -> v == nil end)
      |> Map.new(fn {k, v} -> {if(k == "storage_gib", do: :storage_gb, else: :overlay_gb), v} end)

    capacity = %{disk_gb: 64}

    assert {:ok, pending} =
             ExpansionOps.accept(
               record,
               transition.change["operation_id"],
               record.version,
               targets,
               capacity,
               record.reservation,
               now
             )

    assert {:ok, sent} =
             ExpansionOps.advance(pending, pending.active_expansion, :pending, :dispatch, now + 1)

    {pending, sent}
  end

  defp context(record) do
    %EmbeddedContext{
      config: nil,
      server: self(),
      assignment: record.backend_assignment,
      identity: record.created_machine.backend_identity,
      profile: record.spec.profile,
      spec: record.spec,
      name: record.machine_name,
      growth: NativeGrowth.intent(record)
    }
  end

  defp proof_wire(proof),
    do: proof |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

  test "unknown observation restores only matching completed journal authority without a store write" do
    {original, first, _} = fixture()
    {_, sent} = accept(original, first, 1100)

    assert {:ok, unknown} =
             ExpansionOps.advance(
               sent,
               sent.active_expansion,
               :dispatching,
               {:unknown, %SmolBox.Error{category: :unknown, operation: :expand_disks}},
               1102
             )

    context = context(unknown)
    query = EmbeddedGrowthObservation.request(context)
    assert query["operation"] == "inspect_growth"
    assert query["receipt"] == first.previous
    assert query["request"] == first.change["request"]

    empty = %{stdout: <<>>, stderr: <<>>, file: <<>>}
    outcome = %{"result" => "growth_presence", "transition" => proof_wire(first)}
    result = {:ok, outcome, empty, nil}
    assert {:ok, promoted} = EmbeddedGrowthObservation.promote(context, result)
    assert promoted.identity.receipt == first.receipt
    assert promoted.identity.transition == first and promoted.growth == nil
    assert EmbeddedContext.resources(promoted)["storage_gib"] == 2

    observation = %{
      "result" => "observed",
      "observation" => %{
        "state" => "stopped",
        "resources" => EmbeddedContext.resources(promoted),
        "pid_identity" => nil
      }
    }

    assert {:ok, machine} =
             EmbeddedReply.decode(promoted, :inspect_machine, %{}, {:ok, observation, empty, nil})

    assert {:ok, resolved} =
             ExpansionOps.advance(
               unknown,
               unknown.active_expansion,
               :unknown,
               {:resolve, machine},
               1103
             )

    assert resolved.disk_expansions["grow.1"].state == :resolved
    assert NativeRecovery.observation_valid?(sent, machine)
    assert NativeRecovery.observation_valid?(unknown, machine)
    assert NativeRecovery.observation_valid?(resolved, machine)
    refute NativeRecovery.observation_valid?(original, machine)
    refute NativeRecovery.observation_valid?(resolved, %{machine | storage_gb: 1})
    refute NativeRecovery.observation_valid?(unknown, %{machine | cpus: machine.cpus + 1})
    assert NativeRecovery.observation_valid?(unknown, :missing)
    assert unknown.disk_expansions["grow.1"].state == :unknown
    assert unknown.created_machine == original.created_machine
    assert unknown.reservation.disk_gb == 3 and unknown.disk_sizes.storage_gb == 1

    reference = %SmolBox.Backend.Reference{
      adapter: QualificationPeer,
      kind: :embedded,
      id: unknown.worker_id,
      context: %{observer: self(), grown: machine},
      budget: %SmolBox.Backend.Budget{
        timeout_ms: 1000,
        max_request_bytes: 16_384,
        max_response_bytes: 16_384
      }
    }

    target = %Target{kind: :embedded, id: unknown.worker_id, connection: reference}
    assert {:ok, ^machine} = DiskExpansions.resolution_observation(target, unknown, :stopped)
    assert_receive {:qualified, ^unknown, 1000}
    assert_receive {:inspected, preview, timeout}
    assert timeout < 1000 and timeout > 0
    assert preview.disk_expansions["grow.1"].state == :resolved
    assert preview.observed_machine.backend_identity.receipt == first.receipt
    assert unknown.disk_expansions["grow.1"].state == :unknown
    assert unknown.reservation.disk_gb == 3

    assert {:ok, ^context} =
             EmbeddedGrowthObservation.promote(
               context,
               {:ok, %{outcome | "transition" => nil}, empty, nil}
             )

    for invalid <- [
          put_in(context.growth.id, "foreign"),
          put_in(context.growth.state, :pending),
          put_in(context.growth.previous["storage_gib"], 2),
          put_in(context.growth.targets["overlay_gib"], 2)
        ] do
      assert {:error, %{category: :identity_conflict}} =
               EmbeddedGrowthObservation.promote(invalid, result)
    end

    for invalid <- [
          {:ok, Map.put(outcome, "extra", 1), empty, nil},
          {:ok, outcome, %{empty | stdout: "unrelated"}, nil},
          {:ok, observation, empty, nil},
          {:ok, outcome, empty, %SmolBox.Error{category: :expired, operation: :inspect}}
        ] do
      assert {:error, _} = EmbeddedGrowthObservation.promote(context, invalid)
    end
  end

  defp observed(record, transition) do
    %{
      record.created_machine
      | storage_gb: transition.change["storage_gib"],
        overlay_gb: transition.change["overlay_gib"],
        backend_identity: %Identity{receipt: transition.receipt, transition: transition}
    }
  end

  defp complete(record, transition, now) do
    {_, sent} = accept(record, transition, now)

    assert {:ok, completed} =
             ExpansionOps.advance(
               sent,
               sent.active_expansion,
               :dispatching,
               {:complete, observed(record, transition)},
               now + 2
             )

    completed
  end

  test "successive growth retains creation authority, reservations and exact current proof in v18" do
    {original, first, second} = fixture()
    assert {:ok, <<"smolbox-record-v17\0", _::binary>> = root_bytes} = Codec.encode(original)
    assert {:ok, ^original} = Codec.decode(root_bytes)
    {pending, _} = accept(original, first, 1100)
    assert pending.reservation.disk_gb == 3
    assert {:ok, <<"smolbox-record-v18\0", _::binary>> = pending_bytes} = Codec.encode(pending)
    assert {:ok, ^pending} = Codec.decode(pending_bytes)
    grown = complete(original, first, 1200)
    grown = complete(grown, second, 1300)
    assert grown.created_machine == original.created_machine
    assert grown.spec == original.spec and grown.fingerprint == original.fingerprint
    assert grown.disk_sizes == %{storage_gb: 2, overlay_gb: 3} and grown.reservation.disk_gb == 5
    assert grown.disk_expansions["grow.1"].native_transition == first
    assert grown.disk_expansions["grow.2"].native_transition == second
    assert {:ok, %Identity{receipt: receipt}} = NativeGrowth.current_identity(grown)
    assert receipt == second.receipt
    assert DiskExpansion.expected(grown).backend_identity.receipt == receipt
    assert {:ok, <<"smolbox-record-v18\0", payload::binary>> = bytes} = Codec.encode(grown)
    assert {:ok, ^grown} = Codec.decode(bytes)

    for prefix <- ["smolbox-record-v17\0", "smolbox-record-v16\0", "smolbox-record-v14\0"] do
      assert {:error, _} = Codec.decode(prefix <> payload)
    end

    assert {:error, _} = Codec.decode(bytes <> <<0>>)

    assert {:error, _} =
             Codec.decode("smolbox-record-v18\0" <> :erlang.term_to_binary(grown, compressed: 9))
  end

  test "OCI and prepared registry sources retain both growth links in selective v19" do
    for kind <- [:oci, :registry] do
      {original, first, second} = fixture(kind)
      assert {:ok, <<"smolbox-record-v19\0", _::binary>>} = Codec.encode(original)
      grown = original |> complete(first, 1100) |> complete(second, 1200)
      assert grown.spec == original.spec and grown.fingerprint == original.fingerprint
      assert grown.backend_assignment == original.backend_assignment
      assert grown.preparation == original.preparation
      assert grown.created_machine == original.created_machine
      assert grown.disk_sizes == %{storage_gb: 2, overlay_gb: 3}
      assert grown.reservation.disk_gb == 5
      assert {:ok, %Identity{receipt: receipt}} = NativeGrowth.current_identity(grown)
      assert receipt == second.receipt
      assert {:ok, <<"smolbox-record-v19\0", payload::binary>> = bytes} = Codec.encode(grown)
      assert {:ok, ^grown} = Codec.decode(bytes)

      for version <- 16..18,
          do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

      crossed =
        put_in(
          grown.backend_assignment.creation["source"]["reference"],
          "registry.example/foreign@sha256:" <> String.duplicate("a", 64)
        )

      assert {:error, _} = Codec.encode(crossed)

      if kind == :registry do
        crossed = %{grown.preparation | content_sha256: String.duplicate("c", 64)}
        assert {:error, _} = Codec.encode(%{grown | preparation: crossed})
      else
        crossed = %{grown.observed_machine | network: :offline}
        assert {:error, _} = Codec.encode(%{grown | observed_machine: crossed})
      end
    end
  end

  test "remote-source uncertain growth retains preparation and needs authenticated resolution" do
    for kind <- [:oci, :registry] do
      {original, first, _} = fixture(kind)
      {_, sent} = accept(original, first, 1100)

      assert {:ok, unknown} =
               ExpansionOps.advance(
                 sent,
                 sent.active_expansion,
                 :dispatching,
                 {:unknown, %SmolBox.Error{category: :unknown, operation: :expand_disks}},
                 1102
               )

      assert unknown.reservation.disk_gb == 3
      assert unknown.preparation == original.preparation
      assert unknown.backend_assignment == original.backend_assignment
      assert {:ok, bytes} = Codec.encode(unknown)
      assert {:ok, ^unknown} = Codec.decode(bytes)

      assert {:error, _} =
               ExpansionOps.advance(
                 unknown,
                 unknown.active_expansion,
                 :unknown,
                 {:resolve, %{original.created_machine | storage_gb: 2}},
                 1103
               )

      assert {:ok, resolved} =
               ExpansionOps.advance(
                 unknown,
                 unknown.active_expansion,
                 :unknown,
                 {:resolve, observed(original, first)},
                 1103
               )

      assert resolved.preparation == original.preparation
      assert resolved.disk_expansions["grow.1"].state == :resolved
      assert resolved.reservation.disk_gb == 3
      assert {:ok, bytes} = Codec.encode(resolved)
      assert {:ok, ^resolved} = Codec.decode(bytes)
    end
  end

  test "retained remote-source commands keep historical growth authority without another creation" do
    for kind <- [:oci, :registry] do
      {original, first, second} = fixture(kind)
      before = historical_command(original, "before")
      grown = complete(original, first, 1400)
      between = historical_command(grown, "between")
      final = complete(grown, second, 1500)
      assert HistoricalExecution.matches?(before, final)
      assert HistoricalExecution.matches?(between, final)
      assert between.backend_assignment == original.backend_assignment
      assert between.spec.profile == original.spec.profile
      assert between.created_machine.backend_identity.receipt == first.receipt
      assert {:ok, <<"smolbox-record-v19\0", _::binary>> = bytes} = Codec.encode(between)
      assert {:ok, ^between} = Codec.decode(bytes)

      stripped = put_in(between.created_machine.backend_identity.transition, nil)
      assert {:error, _} = Codec.encode(stripped)
    end
  end

  test "foreign, missing or premature proof cannot complete growth or alter current identity" do
    {original, first, second} = fixture()
    {pending, sent} = accept(original, first, 1100)

    for invalid <- [
          observed(original, second),
          %{observed(original, first) | storage_gb: 3},
          %{observed(original, first) | backend_identity: %Identity{receipt: first.receipt}}
        ] do
      assert {:error, _} =
               ExpansionOps.advance(
                 sent,
                 sent.active_expansion,
                 :dispatching,
                 {:complete, invalid},
                 1102
               )
    end

    premature = put_in(pending.disk_expansions["grow.1"].native_transition, first)
    assert {:error, _} = ManagedMachine.validate(premature)
    grown = complete(original, first, 1200)
    missing = put_in(grown.disk_expansions["grow.1"].native_transition, nil)
    assert {:error, _} = ManagedMachine.validate(missing)
    assert {:error, _} = Codec.encode(missing)

    downgrade =
      put_in(grown.observed_machine.backend_identity, original.created_machine.backend_identity)

    assert {:error, _} = ManagedMachine.validate(downgrade)
    assert {:error, _} = Codec.decode("smolbox-record-v18\0" <> :erlang.term_to_binary(downgrade))
  end

  test "unknown outcomes keep the whole increase and cannot use bare target-size inventory as resolution" do
    {original, first, _} = fixture()
    {_, sent} = accept(original, first, 1100)

    assert {:ok, unknown} =
             ExpansionOps.advance(
               sent,
               sent.active_expansion,
               :dispatching,
               {:unknown, %SmolBox.Error{category: :unknown, operation: :expand_disks}},
               1102
             )

    assert unknown.reservation.disk_gb == 3 and
             unknown.disk_sizes == %{storage_gb: 1, overlay_gb: 1}

    inventory = %{original.created_machine | storage_gb: 2}

    assert {:error, _} =
             ExpansionOps.advance(
               unknown,
               unknown.active_expansion,
               :unknown,
               {:resolve, inventory},
               1103
             )

    assert {:ok, resolved} =
             ExpansionOps.advance(
               unknown,
               unknown.active_expansion,
               :unknown,
               {:resolve, observed(original, first)},
               1103
             )

    assert resolved.disk_expansions["grow.1"].state == :resolved
    assert resolved.disk_expansions["grow.1"].native_transition == first
    assert resolved.reservation.disk_gb == 3
  end

  test "retained commands inherit verified current authority while the original profile stays immutable" do
    {original, first, _} = fixture()
    grown = complete(original, first, 1100)

    running = %{
      grown.observed_machine
      | state: :running,
        backend_identity: %{grown.observed_machine.backend_identity | pid_identity: [123, 456]}
    }

    {:ok, grown} =
      ManagedMachine.update(grown, %{state: :running, observed_machine: running}, 1200)

    {:ok, command} = Command.new(["true"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: original.scope,
        id: "command",
        artifact: original.spec.artifact,
        profile: original.spec.profile,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, execution} = Execution.new(spec, fingerprint, 1300)
    assert {:ok, _held, borrowed} = MachineOps.attach(grown, execution, 1301)
    assert borrowed.spec.profile == original.spec.profile
    assert borrowed.created_machine.storage_gb == 2
    assert borrowed.created_machine.backend_identity.transition == first
    assert :ok = Execution.validate(borrowed)
    assert {:ok, <<"smolbox-record-v18\0", _::binary>> = bytes} = Codec.encode(borrowed)
    assert {:ok, ^borrowed} = Codec.decode(bytes)
    stripped = put_in(borrowed.created_machine.backend_identity.transition, nil)
    assert {:error, _} = Execution.validate(stripped)
    assert {:error, _} = Codec.encode(stripped)
  end

  defp historical_command(parent, id) do
    {:ok, command} = Command.new(["true"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: parent.scope,
        id: id,
        artifact: parent.spec.artifact,
        profile: parent.spec.profile,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, execution} = Execution.new(spec, fingerprint, 1300)
    running = %{parent | state: :running}
    {:ok, _, attached} = MachineOps.attach(running, execution, 1301)

    historical = %{
      attached
      | state: :completed,
        evidence: :exited,
        collection: :complete,
        cleanup: :complete,
        result: %SmolBox.Result{exit_code: 7, stdout: <<0, 255>>, stderr: <<>>}
    }

    assert :ok = Execution.validate(historical)
    historical
  end

  test "historical commands bind to exact material prefixes without acquiring current ownership" do
    {original, first, second} = fixture()
    before = historical_command(original, "before")
    grown = complete(original, first, 1400)
    between = historical_command(grown, "between")
    final = complete(grown, second, 1500)
    assert HistoricalExecution.matches?(before, final)
    assert HistoricalExecution.matches?(between, final)
    unknown = %{before | state: :unknown, evidence: :unknown, result: nil}
    assert HistoricalExecution.matches?(unknown, final)
    refute HistoricalExecution.matches?(between, original)
    refute HistoricalExecution.matches?(historical_command(final, "future"), grown)

    for invalid <- [
          %{before | managed_machine: {"other", "vm"}},
          %{before | worker_generation: 0},
          %{before | cleanup: :pending},
          %{before | reservation: Profile.resources(original.spec.profile)},
          %{before | created_machine: %{before.created_machine | storage_gb: 2}},
          put_in(before.backend_assignment.creation["owner_token"], String.duplicate("f", 64))
        ] do
      refute HistoricalExecution.matches?(invalid, final)
    end

    refute HistoricalExecution.matches?(before, %{final | active_execution: Execution.key(before)})

    refute HistoricalExecution.matches?(before, %{final | disk_expansions: %{}})
    assert before.result.exit_code == 7 and before.cleanup == :complete
  end

  test "collected history survives independent worker lease claims across normal replacements" do
    {original, first, second} = fixture()
    before = historical_command(original, "before-replacement")
    grown = complete(original, first, 1400)
    after_restart = historical_command(%{grown | worker_generation: 2}, "after-replacement")

    advanced = %{complete(grown, second, 1500) | worker_generation: 3, state: :unknown}
    assert {:ok, final, nil} = MachineOps.resolve(advanced, nil, :absent, 1600)

    assert :ok = ManagedMachine.validate(final)

    for historical <- [before, after_restart] do
      assert :ok = Execution.validate(historical)
      assert HistoricalExecution.matches?(historical, final)
      # A collected execution may be claimed after its idle parent last was.
      assert HistoricalExecution.matches?(%{historical | worker_generation: 4}, final)
      refute HistoricalExecution.matches?(%{historical | worker_id: "another-worker"}, final)
      refute HistoricalExecution.matches?(%{historical | cleanup: :pending}, final)
    end
  end

  test "ordinary recovery inspects the grown parent while preserving historical command results" do
    {original, first, second} = fixture()
    before = historical_command(original, "before")
    grown = complete(original, first, 1400)
    between = historical_command(grown, "between")
    between = %{between | state: :unknown, evidence: :unknown, result: nil}
    final = %{complete(grown, second, 1500) | worker_generation: 3}

    native =
      Package.create(
        protocol_major: 2,
        backend: true,
        persistent_backend: true,
        minimum_material_revision: second.receipt["material"]["revision"]
      )

    on_exit(fn -> File.rm_rf!(native.package_path) end)

    native = %{
      native
      | id: original.worker_id,
        domain_generation: original.backend_assignment.binding.generation,
        profiles: [original.spec.profile],
        capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 8},
        artifacts: [
          Map.merge(
            original.spec.artifact,
            %{
              "path" => original.backend_assignment.creation["artifact"]["path"],
              "max_bytes" => 1024
            }
          )
        ]
    }

    assert :ok = Config.validate(native)

    File.write!(
      Path.join(native.package_path, "vm.json"),
      Jason.encode!(%{
        "name" => original.machine_name,
        "state" => "stopped",
        "resources" => %{
          "cpus" => final.created_machine.cpus,
          "memory_mib" => final.created_machine.memory_mb,
          "storage_gib" => 2,
          "overlay_gib" => 3
        }
      })
    )

    store = start_supervised!(Memory)

    :sys.replace_state(store, fn state ->
      %{
        state
        | records: Map.new([before, between], &{Execution.key(&1), &1}),
          machines: %{ManagedMachine.key(final) => final}
      }
    end)

    artifacts = start_supervised!({Agent, fn -> %{} end})

    {:ok, config} =
      RuntimeConfig.new(
        name: __MODULE__.HistoryRuntime,
        namespace: "histmodel",
        mode: :ephemeral,
        store: {Memory, store},
        artifact_store: {SmolBox.TestArtifacts, artifacts},
        fingerprint_key: String.duplicate("k", 32),
        workers: [],
        poll_ms: 20
      )

    config = %{config | workers: [Target.normalize(native)]}

    runtime =
      start_supervised!(%{
        id: __MODULE__.HistoryRuntime,
        start: {Supervisor, :start_link, [SmolBox.Runtime, config, [name: config.name]]},
        type: :supervisor
      })

    deadline = System.monotonic_time(:millisecond) + 10_000
    wait_historical(runtime, deadline)

    for expected <- [before, between] do
      assert {:ok, ^expected} = Memory.fetch(store, Execution.key(expected))
      assert HistoricalExecution.matches?(expected, final)
    end

    all_requests = Package.received(native) |> Enum.filter(&(&1["type"] == "request"))

    assert Enum.all?(
             all_requests,
             &(&1["operation"]["operation"] in ~w(inspect health capacity readiness))
           )

    requests = Enum.filter(all_requests, &Map.has_key?(&1["operation"], "receipt"))

    assert requests != []
    assert Enum.all?(requests, &(&1["operation"]["operation"] == "inspect"))
    assert Enum.all?(requests, &(&1["operation"]["receipt"] == second.receipt))

    target = config.workers |> hd() |> Target.pin()
    stale_reference = Target.connection(target, before)

    assert {:error, %{category: :identity_conflict, evidence: :not_dispatched}} =
             SmolBox.Backend.inspect_machine(stale_reference, before.machine_name)

    assert {:ok, %{disk_gb: 5, slots: 1}} = Memory.usage(store, native.id)
  end

  defp wait_historical(runtime, deadline) do
    unless match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime)) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(20)
      wait_historical(runtime, deadline)
    end
  end

  test "a fresh BEAM decodes v18 from its fixed schema vocabulary without native tooling" do
    {original, first, _} = fixture()
    grown = complete(original, first, 1100)
    {:ok, bytes} = Codec.encode(grown)

    path =
      Path.join(System.tmp_dir!(), "smolbox-growth-record-#{System.unique_integer([:positive])}")

    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code =
      ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do / <>
        ~S/{:ok, %{disk_expansions: %{"grow.1" => %{native_transition: %{schema: 1}}}}} -> IO.puts("fresh-growth"); / <>
        ~S/_ -> System.halt(1) end/

    assert {"fresh-growth\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end

  test "grown wire reply yields an authorized preview without committing dispatch intent" do
    {original, first, _} = fixture()
    {_, intent} = accept(original, first, 1100)
    growth = NativeGrowth.intent(intent)
    assert growth.state == :dispatching and growth.id == "grow.1"

    context = context(intent)
    wire = proof_wire(first)

    request = %{
      "operation" => "expand_disks",
      "receipt" => growth.receipt,
      "operation_id" => growth.id,
      "request" => growth.request,
      "previous" => growth.previous
    }

    outcome = %{
      "result" => "grown",
      "transition" => wire,
      "observation" => %{
        "state" => "stopped",
        "resources" => %{
          "cpus" => original.spec.profile.cpus,
          "memory_mib" => original.spec.profile.memory_mb,
          "storage_gib" => 2,
          "overlay_gib" => 1
        },
        "pid_identity" => nil
      }
    }

    output = %{stdout: <<>>, stderr: <<>>, file: <<>>}

    assert {:ok, grown} =
             EmbeddedReply.decode(context, :expand_disks, request, {:ok, outcome, output, nil})

    assert grown.backend_identity.transition == first

    assert {:ok, unknown} =
             ExpansionOps.advance(
               intent,
               growth.id,
               :dispatching,
               {:unknown, %SmolBox.Error{category: :unknown, operation: :expand_disks}},
               1102
             )

    unknown_context = context(unknown)
    qualification = Map.merge(request, %{"operation" => "qualify_growth", "quiesced" => true})
    qualified = Map.put(outcome, "result", "growth_qualified")

    assert {:ok, qualified_machine} =
             EmbeddedReply.decode(
               unknown_context,
               :qualify_growth,
               qualification,
               {:ok, qualified, output, nil}
             )

    assert qualified_machine.backend_identity.transition == first
    assert {:ok, resolved_preview} = DiskExpansions.resolution_preview(unknown, qualified_machine)
    assert resolved_preview.disk_expansions[growth.id].state == :resolved

    for {request, result} <- [
          {Map.put(qualification, "quiesced", false), qualified},
          {Map.delete(qualification, "quiesced"), qualified},
          {qualification, outcome},
          {qualification, %{"result" => "observed", "observation" => outcome["observation"]}}
        ] do
      assert {:error, _} =
               EmbeddedReply.decode(
                 unknown_context,
                 :qualify_growth,
                 request,
                 {:ok, result, output, nil}
               )
    end

    assert {:ok, preview} =
             ExpansionOps.advance(intent, growth.id, :dispatching, {:complete, grown}, 1102)

    assert preview.observed_machine.backend_identity.receipt == first.receipt
    assert intent.disk_expansions[growth.id].state == :dispatching

    assert intent.created_machine == original.created_machine and
             intent.disk_sizes == %{storage_gb: 1, overlay_gb: 1}

    assert {:error, _} =
             EmbeddedReply.decode(
               context,
               :expand_disks,
               Map.put(request, "operation_id", "foreign"),
               {:ok, outcome, output, nil}
             )

    wrong = put_in(outcome["observation"]["resources"]["cpus"], 2)

    assert {:error, _} =
             EmbeddedReply.decode(context, :expand_disks, request, {:ok, wrong, output, nil})
  end
end
