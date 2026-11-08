defmodule SmolBox.NativeCapturePublicResolutionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedContext, Reference}

  alias SmolBox.Embedded.{
    CaptureAbortSourceQualification,
    Config,
    Identity,
    NativeCaptureResolution,
    NativeGrowth
  }

  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{CaptureOps, Contract, Memory, NativeCaptureContract}

  alias SmolBox.{Checkpoints, ManagedMachine}

  defmodule Clock do
    def now, do: 1103
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call({:quiesce, epoch}, _from, state) do
      send(state.parent, {:quiesce, epoch})

      result =
        cond do
          epoch != state.epoch ->
            {:error, %SmolBox.Error{category: :identity_conflict, operation: :embedded}}

          state.busy ->
            {:error, %SmolBox.Error{category: :admission_exhausted, operation: :embedded}}

          true ->
            :ok
        end

      {:reply, result, %{state | frozen: true}}
    end

    def handle_call({:qualify, capture}, _from, state) do
      send(state.parent, {:qualify, capture.spec.id, state.frozen})
      {:reply, {:ok, state.observed}, state}
    end

    def handle_call(:inspect, _from, state) do
      send(state.parent, :inspect)

      result =
        if state.observed == :absent,
          do: {:error, %SmolBox.Error{category: :not_found, operation: :inspect}},
          else: {:ok, state.observed}

      {:reply, result, state}
    end
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation in [:inspect_machine, :qualify_capture]
    def pin(context, _), do: {:ok, context}

    def assign(context, record),
      do: {:ok, %{context | capture: record.captures[record.active_capture]}}

    def invoke(context, :qualify_capture, [true], _),
      do: GenServer.call(context.server, {:qualify, context.capture})

    def invoke(context, :inspect_machine, [_], _), do: GenServer.call(context.server, :inspect)
  end

  defmodule Host do
    use GenServer
    def start_link(config), do: GenServer.start_link(__MODULE__, config)
    def init(config), do: {:ok, %{config: config, holder: nil}}
    def handle_call(:config, _, state), do: {:reply, {:ok, state.config}, state}

    def handle_call({:native_acquire, id}, {caller, _}, %{holder: nil} = state),
      do: {:reply, :ok, %{state | holder: {id, caller}}}

    def handle_call({:native_release, id}, {caller, _}, %{holder: {id, caller}} = state),
      do: {:reply, :ok, %{state | holder: nil}}
  end

  defp fixture(options \\ []) do
    store = start_supervised!(Memory)
    proofs = NativeCaptureContract.resolution_proofs()
    proofs = if options[:completed], do: nil, else: proofs

    prepared =
      if proofs,
        do: NativeCaptureContract.prepare(Memory, store, proofs),
        else: NativeCaptureContract.prepare(Memory, store)

    {original, _running, sent, spec, proof, _, usage} = prepared
    assert {:ok, unknown} = CaptureOps.cancel(sent, spec.id, 1102)

    assert {:ok, unknown} =
             Memory.machine(store, :capture_advance, [
               ManagedMachine.key(sent),
               Contract.guard(sent),
               spec.id,
               :dispatching,
               [state: :unknown, error: unknown.captures[spec.id].error],
               1102
             ])

    state = source_state(options)

    observed = %{
      unknown.observed_machine
      | state: state,
        backend_identity: %Identity{
          receipt: proof.receipt,
          transition: proof,
          material_history: [proof],
          pid_identity: if(state == :running, do: [123, 456])
        }
    }

    observed = if options[:aborted], do: aborted_observation(unknown, state), else: observed

    observed = if options[:invalid], do: %{observed | cpus: observed.cpus + 1}, else: observed
    observed = if options[:deleted], do: :absent, else: observed
    epoch = String.duplicate("a", 32)

    peer =
      start_supervised!(
        {Peer,
         %{
           parent: self(),
           epoch: epoch,
           busy: options[:busy] || false,
           frozen: false,
           observed: observed
         }}
      )

    context = %EmbeddedContext{
      config: struct(Config),
      server: peer,
      epoch: if(options[:stale_epoch], do: String.duplicate("f", 32), else: epoch),
      pinned: true
    }

    reference = %Reference{
      adapter: Adapter,
      kind: :embedded,
      id: original.worker_id,
      context: context,
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 16_384}
    }

    target = %Target{kind: :embedded, id: original.worker_id, connection: reference}

    config = %{
      managed_machines: true,
      store: {Memory, store},
      workers: [target],
      owner: "owner",
      clock: Clock,
      lease_ms: 10_000,
      poll_ms: 20
    }

    host = %{id: Coordinator, start: {Host, :start_link, [config]}}

    work = %{
      id: WorkSupervisor,
      type: :supervisor,
      start: {Supervisor, :start_link, [[host], [strategy: :one_for_one]]}
    }

    runtime =
      start_supervised!(%{
        id: :model_runtime,
        type: :supervisor,
        start: {Supervisor, :start_link, [[work], [strategy: :one_for_one]]}
      })

    {runtime, store, unknown, spec, usage, proof}
  end

  defp aborted_observation(unknown, state) do
    wire =
      Path.expand("../../native/smolbox-protocol/fixtures/capture-abort-sources-v1.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Enum.find(&(&1["state"] == Atom.to_string(state)))

    {:ok, qualification} = CaptureAbortSourceQualification.from_wire(wire)

    source = %{
      unknown.observed_machine
      | state: state,
        backend_identity: %{
          unknown.observed_machine.backend_identity
          | pid_identity: if(state == :running, do: [123, 456])
        }
    }

    %NativeCaptureResolution{observed: source, qualification: qualification}
  end

  defp source_state(options),
    do: if(options[:completed] == true or options[:running] == true, do: :running, else: :stopped)

  for running <- [false, true] do
    test "public pre-entry running=#{running} resolution consumes source proof under pinned authority" do
      {runtime, store, unknown, spec, _, _} = fixture(aborted: true, running: unquote(running))

      assert {:ok, capture} =
               Checkpoints.resolve(runtime, {unknown.scope, unknown.id, spec.id}, unknown.version,
                 quiesced: true
               )

      assert_receive {:quiesce, _}
      assert_receive {:qualify, _, true}
      assert capture.state == :resolved_unknown and capture.native_transition == nil
      assert capture.native_abort_source != nil and capture.released_at_ms == nil
      assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(unknown)])
      assert saved.created_machine == unknown.created_machine

      assert saved.observed_machine.backend_identity.receipt ==
               unknown.observed_machine.backend_identity.receipt

      assert {:ok, usage} = Memory.usage(store, unknown.worker_id)
      assert usage.disk_gb == unknown.reservation.disk_gb + 1
    end
  end

  test "public entered-capture resolution freezes dispatch and persists source without artifact adoption" do
    {runtime, store, unknown, spec, _usage, proof} = fixture()
    handle = {unknown.scope, unknown.id, spec.id}
    assert {:ok, capture} = Checkpoints.resolve(runtime, handle, unknown.version, quiesced: true)
    assert_receive {:quiesce, _}
    assert_receive {:qualify, _, true}
    refute_receive :inspect
    assert capture.state == :resolved_unknown and capture.result == nil
    assert capture.native_transition == proof and capture.released_at_ms == nil
    assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(unknown)])
    assert saved.created_machine == unknown.created_machine and saved.state == :stopped
    assert {:ok, [^proof]} = NativeGrowth.transitions(saved)
    assert {:ok, usage} = Memory.usage(store, unknown.worker_id)
    assert usage.disk_gb == unknown.reservation.disk_gb + 1
  end

  test "entered journal resolution preserves the exact running source without artifact adoption" do
    {runtime, store, unknown, spec, _, proof} = fixture(running: true)

    assert {:ok, capture} =
             Checkpoints.resolve(runtime, {unknown.scope, unknown.id, spec.id}, unknown.version,
               quiesced: true
             )

    assert capture.state == :resolved_unknown and capture.result == nil
    assert capture.native_transition == proof
    assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(unknown)])

    assert saved.state == :running and
             saved.observed_machine.backend_identity.pid_identity ==
               proof.change["intent"]["source_pid"]

    assert saved.created_machine == unknown.created_machine
  end

  test "completed journal proof may resolve a running unknown source without changing HTTP semantics" do
    {runtime, _store, unknown, spec, _, proof} = fixture(completed: true)

    assert {:ok, capture} =
             Checkpoints.resolve(runtime, {unknown.scope, unknown.id, spec.id}, unknown.version,
               quiesced: true
             )

    assert capture.state == :resolved_unknown and capture.result == nil
    assert capture.native_transition == proof
  end

  test "busy dispatch and crossed observation leave uncertainty and reservations intact" do
    for options <- [[busy: true], [invalid: true], [stale_epoch: true]] do
      {runtime, store, unknown, spec, usage, _} = fixture(options)

      assert {:error, _} =
               Checkpoints.resolve(runtime, {unknown.scope, unknown.id, spec.id}, unknown.version,
                 quiesced: true
               )

      assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(unknown)])

      assert saved.captures[spec.id].state == :unknown and
               saved.captures[spec.id].native_transition == nil

      assert {:ok, ^usage} = Memory.usage(store, unknown.worker_id)
      stop_supervised!(:model_runtime)
      stop_supervised!(Peer)
      stop_supervised!(Memory)
    end
  end

  test "stale record version cannot dispatch source qualification" do
    {runtime, store, unknown, spec, usage, _} = fixture()

    assert {:error, _} =
             Checkpoints.resolve(
               runtime,
               {unknown.scope, unknown.id, spec.id},
               unknown.version - 1,
               quiesced: true
             )

    refute_receive {:qualify, _, _}
    assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(unknown)])
    assert saved.captures[spec.id].state == :unknown
    assert {:ok, ^usage} = Memory.usage(store, unknown.worker_id)
  end

  test "deleted resolution verifies absence through inspection without qualifying present material" do
    {runtime, _store, unknown, spec, _, _} = fixture(deleted: true)

    assert {:ok, capture} =
             Checkpoints.resolve(runtime, {unknown.scope, unknown.id, spec.id}, unknown.version,
               quiesced: true,
               disposition: :deleted
             )

    assert_receive :inspect
    refute_receive {:qualify, _, _}
    assert capture.state == :resolved_unknown and capture.native_transition == nil
  end
end
