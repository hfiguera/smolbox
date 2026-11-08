defmodule SmolBox.NativeGrowthHistoryTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.Backend.{EmbeddedContext, EmbeddedGrowthObservation, EmbeddedReply}
  alias SmolBox.Embedded.{GrowthTransition, Identity, NativeGrowth}
  alias SmolBox.Runtime.{DiskExpansions, NativeRecovery, Target}
  alias SmolBox.Store.{Codec, ExpansionOps, MachineOps}

  alias SmolBox.{
    Command,
    DiskExpansion,
    Execution,
    ExecutionSpec,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    Profile
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

  defp fixture do
    [first, second] =
      "../../native/smolbox-protocol/fixtures/growth-transitions-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn wire ->
        {:ok, proof} = GrowthTransition.from_wire(wire)
        proof
      end)

    {:ok, profile} = Profile.new("growth")

    artifact = %{
      "id" => "fixture",
      "sha256" => String.duplicate("d", 64),
      "architecture" => "aarch64"
    }

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
      backend_identity: %Identity{receipt: receipt}
    }

    assignment = %Assignment{
      version: 2,
      binding: %Binding{
        kind: :embedded,
        target_id: receipt["target_id"],
        generation: receipt["domain_generation"]
      },
      creation: %{
        "name" => receipt["name"],
        "owner_token" => receipt["owner_token"],
        "incarnation" => receipt["incarnation"],
        "artifact" => %{
          "path" => "/fixture.smolmachine",
          "sha256" => artifact["sha256"],
          "max_bytes" => 1024,
          "guest_platform" => "linux/arm64"
        },
        "resources" => %{
          "cpus" => profile.cpus,
          "memory_mib" => profile.memory_mb,
          "storage_gib" => 1,
          "overlay_gib" => 1
        },
        "labels" => %{}
      }
    }

    record = %{
      record
      | backend_assignment: assignment,
        worker_id: receipt["target_id"],
        worker_generation: 1,
        machine_name: receipt["name"],
        reservation: Profile.resources(profile),
        state: :stopped,
        operation: nil,
        phase: nil,
        created_machine: created,
        observed_machine: created
    }

    assert :ok = ManagedMachine.validate(record)
    {record, first, second}
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

  test "a fresh BEAM decodes v18 from its fixed schema vocabulary without native tooling" do
    {original, first, _} = fixture()
    grown = complete(original, first, 1100)
    {:ok, bytes} = Codec.encode(grown)

    path =
      Path.join(System.tmp_dir!(), "smolbox-growth-record-#{System.unique_integer([:positive])}")

    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

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
