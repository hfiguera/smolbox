defmodule SmolBox.DurableNativeProof.Store do
  @moduledoc false
  alias SmolBox.DurableHost.Store, as: Postgres

  for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
      operation not in [:write, :machine] do
    arguments = Macro.generate_arguments(arity - 1, __MODULE__)

    def unquote(operation)({context, _observer}, unquote_splicing(arguments)),
      do: apply(Postgres, unquote(operation), [context, unquote_splicing(arguments)])
  end

  def write({context, observer}, key, guard, changes, now) do
    if observer.fault == "exec-result" and elem(key, 1) == "interrupted" and
         changes[:result] != nil do
      pause(observer, {:execution_result, key, changes[:result]})
    end

    with {:ok, record} <- Postgres.write(context, key, guard, changes, now) do
      if observer.fault == "exec-intent" and record.id == "interrupted" and
           changes[:state] == :dispatching do
        send(observer.pid, {:dispatch_committed, key, self()})

        receive do
          :continue_dispatch -> :ok
        after
          30_000 -> raise "dispatch barrier expired"
        end
      end

      {:ok, record}
    end
  end

  def machine({context, observer}, :write, [key, _guard, changes, _now] = arguments) do
    before_machine_write(observer, key, changes)

    with {:ok, record} <- Postgres.machine(context, :write, arguments) do
      if observer.fault == "create-intent" and record.id == "retained" and
           changes[:phase] == :dispatching do
        creation_barrier(observer, key, nil)
      end

      {:ok, record}
    end
  end

  def machine({context, _observer}, operation, arguments),
    do: Postgres.machine(context, operation, arguments)

  defp before_machine_write(%{fault: "create-receipt"} = observer, {_, "retained"} = key, changes) do
    if changes[:created_machine] != nil,
      do: creation_barrier(observer, key, changes[:created_machine])
  end

  defp before_machine_write(%{fault: "start-receipt"} = observer, {_, "retained"} = key, changes) do
    if match?(%{state: :running}, changes[:observed_machine]),
      do: pause(observer, {:start_boundary, key, changes[:observed_machine]})
  end

  defp before_machine_write(_, _, _), do: :ok

  defp creation_barrier(observer, key, created) do
    pause(observer, {:creation_boundary, key, created})
  end

  defp pause(observer, message) do
    send(observer.pid, message)

    receive do
      :unexpected_continue -> raise "fault barrier must not dispatch or persist"
    after
      30_000 -> raise "fault barrier expired"
    end
  end
end

defmodule SmolBox.DurableNativeProof.Artifacts do
  @moduledoc false
  @behaviour SmolBox.ArtifactStore

  # This proof has no artifact-store inputs or saved outputs. Unexpected use
  # fails rather than pretending that an in-memory artifact store is durable.
  @impl true
  def read(_, _, _, _), do: unavailable()
  @impl true
  def put(_, _, _, _, _), do: unavailable()

  defp unavailable,
    do: {:error, %SmolBox.Error{category: :unsupported_capability, operation: :artifact_store}}
end

defmodule SmolBox.DurableNativeProof do
  @moduledoc false
  alias Ecto.Adapters.SQL
  alias SmolBox.Backend.Binding
  alias SmolBox.Backend.Budget
  alias SmolBox.DurableHost.{RecordCrypto, Repo, Store}
  alias SmolBox.DurableNativeProof.Artifacts
  alias SmolBox.DurableNativeProof.Store, as: BarrierStore
  alias SmolBox.Embedded.{Call, Config, Identity, Port}
  alias SmolBox.Runtime.{NativeAuthority, Target}
  alias SmolBox.Store.Codec

  alias SmolBox.{
    Backend,
    Command,
    ExecutionSpec,
    Files,
    ManagedMachineSpec,
    Profile,
    Runtime
  }

  def run(arguments) do
    {options, [], []} =
      OptionParser.parse(arguments,
        strict: [
          phase: :string,
          package: :string,
          fixture: :string,
          guest_mode: :string,
          sha256: :string,
          domain_json: :string,
          termination: :string,
          fault: :string,
          output: :string
        ]
      )

    phase = Keyword.fetch!(options, :phase)
    true = phase in ["prepare", "recover", "verify", "dispose"]
    output = Path.expand(Keyword.fetch!(options, :output))
    proof = open_proof(phase, output, options)
    verify_fresh_process(output, phase)
    save(output, phase <> "-started.json", Jason.encode!(%{beam_os_pid: System.pid()}))
    {:ok, context} = Store.new(Repo, proof["partition"], File.read!(Path.join(output, "key")))

    {:ok, %{durable: true, backend_bindings: 1, backend_recovery: 1}} =
      Store.capabilities(context)

    {native, profile, artifact} = native(proof)

    {:ok, binding} =
      Store.bind_backend(context, native.id, struct!(Binding, Config.domain_binding(native)))

    true = Map.from_struct(binding) == Config.domain_binding(native)
    options = runtime_options(context, output, native, proof)
    {:ok, runtime} = Runtime.start_link(options)

    try do
      await_ready(runtime)

      apply(__MODULE__, String.to_existing_atom(phase), [
        runtime,
        context,
        output,
        proof,
        profile,
        artifact
      ])
    after
      # Preserve uncertain storage on failure. Deletion is an explicit phase
      # action with a saved full receipt, never an inventory/name sweep.
      Supervisor.stop(runtime)
    end
  end

  def prepare(runtime, context, output, %{"fault" => fault} = proof, profile, artifact)
      when fault in ["create-intent", "create-receipt"] do
    before = inventory()
    save(output, "inventory-before.json", Jason.encode!(before))
    completed_execution(runtime, context, output, proof, profile, artifact)
    {:ok, spec} = retained_spec(profile, artifact)
    {:ok, handle} = SmolBox.Machines.create(runtime, spec)

    created =
      receive do
        {:creation_boundary, ^handle, reply} -> reply
      after
        30_000 -> raise "native creation boundary not observed"
      end

    {:ok, machine} = SmolBox.Machines.inspect(runtime, handle)
    :create = machine.operation
    :dispatching = machine.phase
    nil = machine.created_machine
    true = machine.reservation != nil
    true = created == nil == (fault == "create-intent")

    if created do
      true = Identity.matches?(created.backend_identity, machine.backend_assignment)
      save(output, "out-of-band-receipt.json", Jason.encode!(created.backend_identity.receipt))
    else
      true = inventory() == before
    end

    snapshot(output, "retained-v16.bin", machine)
    {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))
    verify_ciphertexts(context)
    owner = :global.whereis_name({Port, node()})
    {:ok, %{epoch: epoch}} = Port.health(owner)
    save(output, "original-epoch", epoch)
    evidence(output, "prepare", %{fault: fault, receipt_not_persisted: true, reserved_slots: 1})
    kill_barrier(output, owner)
  end

  def prepare(runtime, context, output, %{"fault" => "start-receipt"} = proof, profile, artifact) do
    before = inventory()
    save(output, "inventory-before.json", Jason.encode!(before))
    completed_execution(runtime, context, output, proof, profile, artifact)
    {:ok, spec} = retained_spec(profile, artifact)
    {:ok, handle} = SmolBox.Machines.create(runtime, spec)
    {:ok, %{state: :stopped} = stopped} = SmolBox.Machines.await(runtime, handle, 120_000)
    {:ok, _} = lifecycle(runtime, handle, :start)

    reply =
      receive do
        {:start_boundary, ^handle, observed} -> observed
      after
        30_000 -> raise "native start reply boundary not observed"
      end

    :running = reply.state
    [pid, started] = reply.backend_identity.pid_identity
    true = is_integer(pid) and pid > 0 and is_integer(started)
    {:ok, machine} = SmolBox.Machines.inspect(runtime, handle)
    :start = machine.operation
    :dispatching = machine.phase
    true = machine.created_machine == stopped.created_machine
    true = machine.observed_machine == stopped.observed_machine
    snapshot(output, "retained-v16.bin", machine)

    save(
      output,
      "out-of-band-start.json",
      Jason.encode!(%{state: "running", pid_identity: [pid, started]})
    )

    {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))
    verify_ciphertexts(context)
    owner = :global.whereis_name({Port, node()})
    {:ok, %{epoch: epoch}} = Port.health(owner)
    save(output, "original-epoch", epoch)
    evidence(output, "prepare", %{start_reply_not_persisted: true, reserved_slots: 1})
    kill_barrier(output, owner)
  end

  def prepare(runtime, context, output, proof, profile, artifact) do
    before = inventory()
    save(output, "inventory-before.json", Jason.encode!(before))
    completed_execution(runtime, context, output, proof, profile, artifact)
    {:ok, machine_spec} = retained_spec(profile, artifact)

    {:ok, retained} = SmolBox.Machines.create(runtime, machine_spec)
    {:ok, %{state: :stopped}} = SmolBox.Machines.await(runtime, retained, 120_000)
    {:ok, _} = lifecycle(runtime, retained, :start)
    {:ok, %{state: :running}} = SmolBox.Machines.await(runtime, retained, 120_000)

    {:ok, command_spec} =
      execution(proof, profile, artifact, "interrupted", interrupted_argv(proof))

    {:ok, command} = SmolBox.Machines.submit(runtime, retained, command_spec)

    dispatcher = dispatch_boundary(output, proof, command)

    {:ok, dispatching} = Store.fetch(context, command)
    true = dispatching.state in [:dispatching, :running]
    nil = dispatching.result
    snapshot(output, "dispatch-intent-v16.bin", dispatching)
    owner = :global.whereis_name({Port, node()})
    {:ok, %{epoch: epoch}} = Port.health(owner)
    save(output, "original-epoch", epoch)
    finish_prepare(runtime, context, output, proof, retained, command, dispatcher, owner)
  end

  defp completed_execution(runtime, context, output, proof, profile, artifact) do
    {:ok, spec} =
      execution(proof, profile, artifact, "completed", [
        "/bin/sh",
        "-c",
        "printf durable-witness; exit 7"
      ])

    {:ok, handle} = SmolBox.submit(runtime, spec)

    {:ok, %{state: :completed, result: %{exit_code: 7, stdout: "durable-witness"}}} =
      SmolBox.await(runtime, handle, 120_000)

    completed = wait_clean(context, handle)
    snapshot(output, "completed-v16.bin", completed)
  end

  defp retained_spec(profile, artifact),
    do:
      ManagedMachineSpec.new(
        scope: "durable-native",
        id: "retained",
        profile: profile,
        artifact: artifact
      )

  defp finish_prepare(
         runtime,
         context,
         output,
         %{"termination" => "sigkill"} = proof,
         retained,
         command,
         _dispatcher,
         owner
       ) do
    {:ok, machine} = SmolBox.Machines.inspect(runtime, retained)
    :running = machine.state
    ^command = machine.active_execution
    true = machine.reservation != nil
    {:ok, interrupted} = Store.fetch(context, command)
    true = interrupted.state in [:dispatching, :running]
    nil = interrupted.result
    snapshot(output, "unknown-v16.bin", interrupted)
    snapshot(output, "retained-v16.bin", machine)
    {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))
    verify_ciphertexts(context)

    evidence(output, "prepare", %{
      committed_dispatch_intent: true,
      pending_sigkill: true,
      result_reply_not_persisted: proof["fault"] == "exec-result",
      reserved_slots: 1
    })

    kill_barrier(output, owner)
  end

  defp finish_prepare(runtime, context, output, proof, retained, command, dispatcher, owner) do
    :ok = GenServer.stop(owner)
    send(dispatcher, :continue_dispatch)
    {:ok, %{state: :unknown, result: nil}} = SmolBox.await(runtime, command, 120_000)
    await_ready(runtime)
    {:ok, machine} = SmolBox.Machines.inspect(runtime, retained)
    :unknown = machine.state
    ^command = machine.active_execution
    true = machine.reservation != nil
    {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))
    {:ok, interrupted} = Store.fetch(context, command)
    :unknown = interrupted.state
    :unknown = interrupted.evidence
    nil = interrupted.result
    snapshot(output, "unknown-v16.bin", interrupted)
    snapshot(output, "retained-v16.bin", machine)
    verify_ciphertexts(context)

    evidence(output, "prepare", %{
      committed_dispatch_intent: true,
      unknown_without_exit: true,
      reserved_slots: 1
    })
  end

  defp kill_barrier(output, owner) do
    {:os_pid, helper_pid} = Elixir.Port.info(:sys.get_state(owner).port, :os_pid)

    save(
      output,
      "ready-for-kill.json",
      Jason.encode!(%{beam_os_pid: System.pid(), helper_os_pid: helper_pid})
    )

    receive do
      :unexpected_continue -> raise "kill barrier must not dispatch"
    after
      25_000 -> raise "external SIGKILL not observed"
    end
  end

  def recover(runtime, context, output, %{"fault" => fault} = proof, _profile, _artifact)
      when fault in ["create-intent", "create-receipt"] do
    verify_termination(output, proof)
    previous = decode(output, "retained-v16.bin")
    handle = {previous.scope, previous.id}
    {:ok, recovered} = SmolBox.Machines.inspect(runtime, handle)
    :unknown = recovered.state
    nil = recovered.created_machine
    nil = recovered.active_execution
    true = recovered.backend_assignment == previous.backend_assignment
    true = recovered.reservation == previous.reservation
    {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))

    {:ok, first_page} = SmolBox.audit_worker(runtime, target_id(proof))
    true = first_page.next_cursor != nil

    {:ok, %{candidates: [%{status: :unverified, managed_machine: ^handle}]}} =
      SmolBox.audit_worker(runtime, target_id(proof), cursor: first_page.next_cursor)

    {:error, %{category: :unsupported_capability}} = resolve(runtime, handle)
    owner = :global.whereis_name({Port, node()})
    {:ok, %{epoch: epoch}} = Port.health(owner)
    true = epoch != File.read!(Path.join(output, "original-epoch"))
    snapshot(output, "recovered-v16.bin", recovered)

    if fault == "create-receipt" do
      {:error, %{category: :identity_conflict}} = resolve_deleted(runtime, handle)
      {:ok, still_reserved} = SmolBox.Machines.inspect(runtime, handle)
      nil = still_reserved.created_machine
      true = still_reserved.reservation == previous.reservation
      true = still_reserved.backend_assignment == previous.backend_assignment
      {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))
      snapshot(output, "unverified-v16.bin", still_reserved)
      receipt_cleanup(runtime, context, output, proof, previous)
    end

    {:ok, deleted} = resolve_deleted(runtime, handle)
    :deleted = deleted.state
    nil = deleted.reservation
    nil = deleted.created_machine
    true = deleted.backend_assignment == previous.backend_assignment
    true = is_integer(deleted.absence_at_ms)
    snapshot(output, "deleted-v16.bin", deleted)
    verify_completed(context, output)
    {:ok, %{slots: 0}} = Store.usage(context, target_id(proof))
    true = inventory() == Jason.decode!(File.read!(Path.join(output, "inventory-before.json")))
    verify_ciphertexts(context)

    evidence(output, "recover", %{
      fault: fault,
      fresh_beam: true,
      automatic_recovery_kept_reservation: true,
      receipt_not_adopted: true,
      stopped_resolution_unsupported: true,
      present_material_refused: fault == "create-receipt",
      explicit_absence_released_capacity: true,
      historical_completed_unchanged: true,
      reserved_slots: 0
    })
  end

  def recover(
        runtime,
        context,
        output,
        %{"fault" => "start-receipt"} = proof,
        _profile,
        _artifact
      ) do
    verify_termination(output, proof)
    previous = decode(output, "retained-v16.bin")
    handle = {previous.scope, previous.id}
    {:ok, recovered} = SmolBox.Machines.inspect(runtime, handle)
    :unknown = recovered.state
    nil = recovered.active_execution
    true = recovered.created_machine == previous.created_machine
    true = recovered.backend_assignment == previous.backend_assignment
    true = recovered.reservation == previous.reservation
    {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))
    {:ok, config} = GenServer.call(Runtime.coordinator(runtime), :config)
    reference = Target.connection(hd(config.workers), recovered)
    {:ok, %{state: :stopped}} = Backend.inspect_machine(reference, recovered.machine_name)
    owner = :global.whereis_name({Port, node()})
    {:ok, %{epoch: epoch}} = Port.health(owner)
    true = epoch != File.read!(Path.join(output, "original-epoch"))
    snapshot(output, "recovered-v16.bin", recovered)
    {:ok, %{state: :stopped, reservation: reservation}} = resolve(runtime, handle)
    true = reservation == previous.reservation
    await_ready(runtime)
    {:ok, _} = lifecycle(runtime, handle, :delete)

    {:ok, %{state: :deleted, reservation: nil} = deleted} =
      SmolBox.Machines.await(runtime, handle, 120_000)

    snapshot(output, "deleted-v16.bin", deleted)
    verify_completed(context, output)
    {:ok, %{slots: 0}} = Store.usage(context, target_id(proof))
    true = inventory() == Jason.decode!(File.read!(Path.join(output, "inventory-before.json")))
    verify_ciphertexts(context)

    evidence(output, "recover", %{
      fresh_beam: true,
      stopped_after_owner_loss: true,
      start_not_replayed: true,
      receipt_authority_preserved: true,
      reserved_slots: 0
    })
  end

  def recover(runtime, context, output, proof, profile, artifact) do
    verify_termination(output, proof)
    previous = decode(output, "retained-v16.bin")
    previous_command = decode(output, "unknown-v16.bin")
    retained = {previous.scope, previous.id}
    command = {previous_command.scope, previous_command.id}
    {:ok, recovered} = SmolBox.Machines.inspect(runtime, retained)
    :unknown = recovered.state
    ^command = recovered.active_execution
    true = recovered.created_machine == previous.created_machine
    true = recovered.backend_assignment == previous.backend_assignment
    true = recovered.reservation == previous.reservation
    {:ok, %{state: :unknown, result: nil} = unknown} = Store.fetch(context, command)
    :unknown = unknown.evidence
    true = unknown.spec == previous_command.spec
    true = unknown.backend_assignment == previous_command.backend_assignment
    {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))
    {:ok, config} = GenServer.call(Runtime.coordinator(runtime), :config)
    reference = Target.connection(hd(config.workers), recovered)
    {:ok, %{state: :stopped}} = Backend.inspect_machine(reference, recovered.machine_name)
    owner = :global.whereis_name({Port, node()})
    {:ok, %{epoch: epoch}} = Port.health(owner)
    true = epoch != File.read!(Path.join(output, "original-epoch"))
    snapshot(output, "recovered-v16.bin", recovered)
    {:ok, resolved} = resolve(runtime, retained)
    :stopped = resolved.state
    nil = resolved.active_execution
    true = resolved.reservation == previous.reservation
    await_ready(runtime)

    {:ok, %{state: :unknown, result: nil, cleanup: :complete} = preserved} =
      Store.fetch(context, command)

    snapshot(output, "resolved-command-v16.bin", preserved)
    # Only after explicit stopped resolution, start a new legitimate command.
    # The persistent guest marker detects replay across the controller restart.
    {:ok, _} = lifecycle(runtime, retained, :start)
    {:ok, %{state: :running}} = SmolBox.Machines.await(runtime, retained, 120_000)

    {:ok, check} =
      execution(proof, profile, artifact, "no-replay", replay_check_argv(proof))

    {:ok, check_handle} = SmolBox.Machines.submit(runtime, retained, check)

    {:ok, %{state: :completed, result: %{exit_code: 0}}} =
      SmolBox.await(runtime, check_handle, 120_000)

    _ = wait_clean(context, check_handle)
    {:ok, ^preserved} = Store.fetch(context, command)
    {:ok, _} = lifecycle(runtime, retained, :stop)
    {:ok, %{state: :stopped}} = SmolBox.Machines.await(runtime, retained, 120_000)
    {:ok, _} = lifecycle(runtime, retained, :delete)

    {:ok, %{state: :deleted, reservation: nil} = deleted} =
      SmolBox.Machines.await(runtime, retained, 120_000)

    true = is_integer(deleted.absence_at_ms)
    {:ok, %{slots: 0}} = Store.usage(context, target_id(proof))
    snapshot(output, "deleted-v16.bin", deleted)
    true = inventory() == Jason.decode!(File.read!(Path.join(output, "inventory-before.json")))
    verify_ciphertexts(context)

    evidence(output, "recover", %{
      fresh_beam: true,
      stopped_receipt_preserved: true,
      unknown_slot_preserved: true,
      no_replay_marker: true,
      explicit_resolution_preserved_unknown: true,
      result_reply_not_adopted: Map.get(proof, "fault") == "exec-result",
      absence_confirmed: true,
      reserved_slots: 0,
      sigkill_dispatch_intent_qualified: proof["termination"] == "sigkill"
    })
  end

  def verify(_runtime, context, output, %{"fault" => fault} = proof, _profile, _artifact)
      when fault in ["create-intent", "create-receipt", "start-receipt"] do
    previous = decode(output, "deleted-v16.bin")
    {:ok, deleted} = Store.machine(context, :fetch, [{previous.scope, previous.id}])
    :deleted = deleted.state
    nil = deleted.reservation
    true = deleted.created_machine == previous.created_machine
    true = deleted.backend_assignment == previous.backend_assignment
    true = deleted.absence_at_ms == previous.absence_at_ms
    verify_completed(context, output)
    {:ok, %{slots: 0}} = Store.usage(context, target_id(proof))
    true = inventory() == Jason.decode!(File.read!(Path.join(output, "inventory-before.json")))
    verify_ciphertexts(context)

    evidence(output, "verify", %{
      fault: fault,
      fresh_beam: true,
      receipt_authority_preserved: true,
      historical_completed_unchanged: true,
      reserved_slots: 0
    })
  end

  def verify(_runtime, context, output, proof, _profile, _artifact) do
    previous = decode(output, "deleted-v16.bin")
    {:ok, deleted} = Store.machine(context, :fetch, [{previous.scope, previous.id}])
    :deleted = deleted.state
    nil = deleted.reservation
    true = deleted.absence_at_ms == previous.absence_at_ms
    true = deleted.created_machine == previous.created_machine
    true = deleted.backend_assignment == previous.backend_assignment
    completed = decode(output, "completed-v16.bin")
    {:ok, ^completed} = Store.fetch(context, {completed.scope, completed.id})
    previous_command = decode(output, "resolved-command-v16.bin")
    {:ok, ^previous_command} = Store.fetch(context, {previous_command.scope, previous_command.id})
    {:ok, %{slots: 0}} = Store.usage(context, target_id(proof))
    true = inventory() == Jason.decode!(File.read!(Path.join(output, "inventory-before.json")))
    verify_ciphertexts(context)

    evidence(output, "verify", %{
      fresh_beam: true,
      deleted_tombstone_preserved: true,
      historical_unknown_unchanged: true,
      reserved_slots: 0
    })
  end

  def dispose(runtime, context, output, %{"fault" => fault} = proof, _profile, _artifact)
      when fault in ["create-intent", "create-receipt"] do
    handle = {"durable-native", "retained"}
    {:ok, previous} = SmolBox.Machines.inspect(runtime, handle)
    nil = previous.created_machine

    if previous.state != :deleted do
      if File.exists?(Path.join(output, "out-of-band-receipt.json")),
        do: receipt_cleanup(runtime, context, output, proof, previous)

      {:ok, %{state: :deleted, reservation: nil}} = resolve_deleted(runtime, handle)
    end

    {:ok, %{slots: 0}} = Store.usage(context, target_id(proof))

    evidence(output, "dispose", %{
      fault: fault,
      explicit_absence_resolution: true,
      reserved_slots: 0
    })
  end

  def dispose(runtime, context, output, proof, _profile, _artifact) do
    handle = {"durable-native", "retained"}
    {:ok, machine} = SmolBox.Machines.inspect(runtime, handle)
    true = machine.created_machine != nil

    if machine.state == :unknown do
      {:ok, %{state: :stopped}} = resolve(runtime, handle)
      await_ready(runtime)
    end

    {:ok, current} = SmolBox.Machines.inspect(runtime, handle)

    if current.state != :deleted do
      {:ok, _} = lifecycle(runtime, handle, :delete)

      {:ok, %{state: :deleted, reservation: nil}} =
        SmolBox.Machines.await(runtime, handle, 120_000)
    end

    {:ok, %{slots: 0}} = Store.usage(context, target_id(proof))
    evidence(output, "dispose", %{receipt_bound_deletion: true, reserved_slots: 0})
  end

  defp open_proof("prepare", output, options) do
    :ok = File.mkdir(output)
    :ok = File.chmod(output, 0o700)

    termination = Keyword.get(options, :termination, "owner-restart")
    true = termination in ["owner-restart", "sigkill"]
    fault = Keyword.get(options, :fault, "exec-intent")

    true =
      fault in ["exec-intent", "exec-result", "create-intent", "create-receipt", "start-receipt"]

    true = fault == "exec-intent" or termination == "sigkill"
    guest_mode = Keyword.get(options, :guest_mode, "container")
    true = guest_mode in ["container", "vm"]

    proof = %{
      "termination" => termination,
      "fault" => fault,
      "partition" =>
        "native-proof-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower),
      "package" => Path.expand(Keyword.fetch!(options, :package)),
      "fixture" => Path.expand(Keyword.fetch!(options, :fixture)),
      "guest_mode" => guest_mode,
      "sha256" => Keyword.fetch!(options, :sha256),
      "domain" => options |> Keyword.fetch!(:domain_json) |> File.read!() |> Jason.decode!()
    }

    proof =
      Map.put(
        proof,
        "package_manifest_sha256",
        Files.sha256(File.read!(Path.join(proof["package"], "package.json")))
      )

    save(output, "key", :crypto.strong_rand_bytes(32))
    save(output, "proof.json", Jason.encode!(proof))
    proof
  end

  defp open_proof("dispose", output, _options),
    do: Jason.decode!(File.read!(Path.join(output, "proof.json")))

  defp open_proof(phase, output, _options) do
    prior = if phase == "recover", do: "prepare", else: "recover"
    true = File.exists?(Path.join(output, prior <> "-result.json"))
    false = File.exists?(Path.join(output, phase <> "-result.json"))
    Jason.decode!(File.read!(Path.join(output, "proof.json")))
  end

  defp native(proof) do
    package = proof["package"]
    bytes = File.read!(Path.join(package, "package.json"))
    true = Files.sha256(bytes) == proof["package_manifest_sha256"]
    identity = Jason.decode!(bytes)["identity"]
    {:ok, profile} = Profile.new("durable-proof", cpus: 1, memory_mb: 512)

    artifact = %{
      "id" => "proof",
      "sha256" => proof["sha256"],
      "architecture" => identity["architecture"]
    }

    {:ok, config} =
      Config.new(
        id: target_id(proof),
        package_path: package,
        package_manifest_sha256: Files.sha256(bytes),
        package_identity: identity,
        domain_generation: proof["domain"]["generation"],
        platform: platform(identity["platform"]),
        architecture: identity["architecture"],
        profiles: [profile],
        artifacts: [
          Map.merge(artifact, %{
            "path" => proof["fixture"],
            "max_bytes" => File.stat!(proof["fixture"]).size
          })
        ],
        capacity: %{slots: 1, cpus: 1, memory_mb: 768, disk_gb: 2},
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256}
      )

    {config, profile, artifact}
  end

  defp runtime_options(context, output, native, proof) do
    [
      name: __MODULE__,
      namespace: "durable",
      store:
        {BarrierStore, {context, %{pid: self(), fault: Map.get(proof, "fault", "exec-intent")}}},
      mode: :durable,
      fingerprint_key: File.read!(Path.join(output, "key")),
      artifact_store: {Artifacts, nil},
      workers: [native],
      poll_ms: 100,
      lease_ms: 5000
    ]
  end

  defp execution(proof, profile, artifact, id, argv) do
    user = guest_user(proof)
    {:ok, command} = Command.new(argv, user: user, timeout_secs: 10)

    ExecutionSpec.new(
      scope: "durable-native",
      id: id,
      profile: profile,
      artifact: artifact,
      command: command
    )
  end

  defp guest_user(%{"guest_mode" => "vm"}), do: nil
  defp guest_user(%{"fault" => fault}) when fault in ["exec-intent", "exec-result"], do: "0:0"
  defp guest_user(_proof), do: "65534:65534"

  defp interrupted_argv(%{"fault" => "exec-result"}),
    do: [
      "/bin/sh",
      "-c",
      "n=$(cat /workspace/run-count 2>/dev/null || printf 0); printf '%s' \"$((n+1))\" > /workspace/run-count; printf durable-once-result; exit 7"
    ]

  defp interrupted_argv(_proof),
    do: ["/bin/sh", "-c", "printf forbidden > /workspace/forbidden-replay"]

  defp replay_check_argv(%{"fault" => "exec-result"}),
    do: ["/bin/sh", "-c", "test \"$(cat /workspace/run-count)\" = 1; exit $?"]

  defp replay_check_argv(_proof),
    do: ["/bin/sh", "-c", "test ! -e /workspace/forbidden-replay; exit $?"]

  defp dispatch_boundary(output, %{"fault" => "exec-result"}, command) do
    receive do
      {:execution_result, key, result} ->
        true = key == command
        %{exit_code: 7, stdout: "durable-once-result", stderr: ""} = result

        save(
          output,
          "out-of-band-result.json",
          Jason.encode!(Map.take(result, [:exit_code, :stdout, :stderr]))
        )

        nil
    after
      30_000 -> raise "native result persistence boundary not observed"
    end
  end

  defp dispatch_boundary(_output, _proof, command) do
    receive do
      {:dispatch_committed, ^command, pid} -> pid
    after
      30_000 -> raise "durable dispatch intent not observed"
    end
  end

  defp verify_termination(output, %{"termination" => "sigkill"}) do
    started = Jason.decode!(File.read!(Path.join(output, "prepare-started.json")))
    killed = Jason.decode!(File.read!(Path.join(output, "kill-observed.json")))
    true = killed["beam_os_pid"] == started["beam_os_pid"]
    9 = killed["exit_signal"]
    true = killed["helper_exit_observed"]
  end

  defp verify_termination(_output, _proof), do: :ok

  defp verify_fresh_process(output, phase) do
    for prior <- ["prepare", "recover"], prior != phase do
      path = Path.join(output, prior <> "-started.json")

      if File.exists?(path),
        do: true = Jason.decode!(File.read!(path))["beam_os_pid"] != System.pid()
    end
  end

  defp lifecycle(runtime, handle, action), do: retry_mutation(runtime, handle, action, [], 100)

  defp resolve(runtime, handle),
    do: retry_mutation(runtime, handle, :resolve, [quiesced: true], 100)

  defp resolve_deleted(runtime, handle),
    do: retry_mutation(runtime, handle, :resolve, [quiesced: true, disposition: :deleted], 100)

  # Qualification-only operator cleanup uses the authentic reply saved outside
  # the application record. It never injects that receipt into durable recovery.
  defp receipt_cleanup(runtime, context, output, proof, previous) do
    receipt = Jason.decode!(File.read!(Path.join(output, "out-of-band-receipt.json")))
    true = Identity.matches?(%Identity{receipt: receipt}, previous.backend_assignment)
    {:ok, config} = GenServer.call(Runtime.coordinator(runtime), :config)
    target = Target.pin(hd(config.workers))
    connection = target.connection.context
    budget = %Budget{timeout_ms: 30_000, max_request_bytes: 16_384, max_response_bytes: 16_384}

    NativeAuthority.run(Runtime.coordinator(runtime), target.id, fn ->
      :ok = Port.quiesce(connection.server, connection.epoch)

      :ok =
        Port.activate(
          connection.server,
          Config.domain_binding(connection.config),
          connection.epoch
        )

      {:ok, %{"result" => "observed", "observation" => %{"state" => state}}, _, nil} =
        Call.run(connection, %{"operation" => "inspect", "receipt" => receipt}, budget)

      true = state in ["stopped", "missing"]

      if state == "stopped" do
        {:ok, %{"result" => "observed", "observation" => %{"state" => "missing"}}, _, nil} =
          Call.run(connection, %{"operation" => "delete", "receipt" => receipt}, budget)
      end

      {:ok, %{created_machine: nil} = current} =
        Store.machine(context, :fetch, [{previous.scope, previous.id}])

      true = current.backend_assignment == previous.backend_assignment
      true = current.reservation == previous.reservation
      {:ok, %{slots: 1}} = Store.usage(context, target_id(proof))
    end)
  end

  defp verify_completed(context, output) do
    completed = decode(output, "completed-v16.bin")
    {:ok, ^completed} = Store.fetch(context, {completed.scope, completed.id})
  end

  defp retry_mutation(runtime, handle, action, options, remaining) do
    {:ok, record} = SmolBox.Machines.inspect(runtime, handle)

    arguments =
      if action == :resolve,
        do: [runtime, handle, record.version, options],
        else: [runtime, handle, record.version]

    result = apply(SmolBox.Machines, action, arguments)

    case result do
      {:error, %{category: category, evidence: :not_dispatched}}
      when category in [:stale_version, :admission_exhausted] and remaining > 0 ->
        Process.sleep(10)
        retry_mutation(runtime, handle, action, options, remaining - 1)

      _ ->
        result
    end
  end

  defp await_ready(runtime) do
    wait(fn -> match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime)) end, 15_000)
  end

  defp wait_clean(context, handle) do
    wait(fn -> match?({:ok, %{cleanup: :complete}}, Store.fetch(context, handle)) end, 15_000)
    {:ok, record} = Store.fetch(context, handle)
    record
  end

  defp wait(function, remaining) do
    cond do
      function.() ->
        :ok

      remaining > 0 ->
        Process.sleep(20)
        wait(function, remaining - 20)

      true ->
        raise "qualification condition timed out"
    end
  end

  defp verify_ciphertexts(context) do
    for {table, kind} <- [
          {"smolbox_executions", :execution},
          {"smolbox_managed_machines", :machine}
        ] do
      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT scope,execution_id,payload FROM #{table} WHERE partition=$1",
          [context.partition]
        )

      for [scope, id, payload] <- rows do
        <<1, _::binary>> = payload

        {:ok, record} =
          RecordCrypto.decrypt(payload, context.key, context.partition, {scope, id}, kind)

        {:ok, encoded} = Codec.encode(record)
        true = encoded != payload
        {:ok, ^record} = Codec.decode(encoded)
      end

      true = rows != []
    end
  end

  defp snapshot(output, name, record) do
    {:ok, bytes} = Codec.encode(record)
    {:ok, ^record} = Codec.decode(bytes)
    save(output, name, bytes)
  end

  defp decode(output, name) do
    {:ok, record} = Codec.decode(File.read!(Path.join(output, name)))
    record
  end

  defp save(output, name, bytes) do
    {:ok, file} = File.open(Path.join(output, name), [:write, :binary, :exclusive, :sync])
    :ok = File.chmod(Path.join(output, name), 0o600)
    :ok = IO.binwrite(file, bytes)
    :ok = :file.sync(file)
    :ok = File.close(file)

    {_, 0} =
      System.cmd("python3", [
        "-c",
        "import os,sys; f=os.open(sys.argv[1],os.O_RDONLY); os.fsync(f); os.close(f)",
        output
      ])
  end

  defp evidence(output, phase, result) do
    proof = Jason.decode!(File.read!(Path.join(output, "proof.json")))

    result =
      Map.merge(result, %{
        phase: phase,
        proof: "passed",
        scope: "public-postgresql-native-runtime",
        public_native_admission_enabled: true,
        beam_os_pid: System.pid(),
        native_package_manifest_sha256: proof["package_manifest_sha256"],
        guest_mode: Map.get(proof, "guest_mode", "container"),
        fault: Map.get(proof, "fault", "exec-intent"),
        elixir_version: System.version(),
        otp_version: System.otp_release(),
        whole_fault_matrix_qualified: false
      })

    save(output, phase <> "-result.json", Jason.encode!(result))
    IO.puts(Jason.encode!(result))
  end

  defp inventory do
    script = Path.expand("../../../native/smolbox-port/tests", __DIR__)

    {body, 0} =
      System.cmd("python3", [
        "-c",
        "import sys,json; sys.path.insert(0,sys.argv[1]); from native_proof import snapshot; print(json.dumps(snapshot()))",
        script
      ])

    Jason.decode!(body)
  end

  defp target_id(proof), do: proof["domain"]["target_id"]
  defp platform("macos"), do: :macos
  defp platform("linux"), do: :linux
end

SmolBox.DurableNativeProof.run(System.argv())
