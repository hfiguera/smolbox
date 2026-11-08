defmodule SmolBox.NativeExportPublicResolutionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedContext, Reference}
  alias SmolBox.Embedded.{Config, ExportStageCleanup}
  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Contract, Memory, NativeExportContract}
  alias SmolBox.{ExportDestination, ExportReceipt, ExportResult, Exports, ManagedMachine}

  defmodule Clock do
    def now, do: 1104
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call({:quiesce, epoch}, _, state) do
      send(state.parent, {:quiesce, epoch})

      result =
        cond do
          epoch != state.epoch ->
            {:error, %SmolBox.Error{category: :identity_conflict, operation: :export}}

          state.busy ->
            {:error, %SmolBox.Error{category: :admission_exhausted, operation: :export}}

          true ->
            :ok
        end

      {:reply, result, %{state | frozen: result == :ok}}
    end

    def handle_call({:cleanup, export}, _, state) do
      Process.sleep(state.delay_ms)
      send(state.parent, {:cleanup, export.spec.id, state.frozen})

      proof = %ExportStageCleanup{
        schema: 1,
        source: export.native_authority.source,
        operation_id: export.spec.id,
        request_sha256: export.fingerprint,
        stage_sha256: String.duplicate("b", 64)
      }

      response =
        case state.reply do
          :proof ->
            {:ok, proof}

          :foreign ->
            {:ok, %{proof | operation_id: "foreign"}}

          :uncertain ->
            {:error,
             %SmolBox.Error{category: :unknown, operation: :export, evidence: :dispatch_uncertain}}
        end

      {:reply, response, state}
    end

    def handle_call(:inspect, _, state) do
      send(state.parent, {:inspect, state.frozen})

      {:reply,
       if(state.deleted,
         do: {:error, %SmolBox.Error{category: :not_found, operation: :inspect}},
         else: {:ok, state.observed}
       ), state}
    end
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation in [:cleanup_export, :inspect_machine]
    def pin(context, _), do: {:ok, context}

    def assign(context, record),
      do: {:ok, %{context | export: record.exports[record.active_export]}}

    def invoke(context, :cleanup_export, [export, true], _),
      do: GenServer.call(context.server, {:cleanup, export})

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

  defp fixture(mode, options \\ []) do
    store = start_supervised!(Memory)

    {stopped, record, spec, proof} =
      NativeExportContract.prepare(Memory, store, mode != :published)

    record =
      if mode == :published do
        receipt = %ExportReceipt{
          manifest_sha256: proof.identity["manifest_sha256"],
          size_bytes: proof.identity["size_bytes"],
          platform: proof.identity["platform"],
          native_publication: proof
        }

        assert {:ok, verifying} =
                 Memory.machine(store, :export_advance, [
                   ManagedMachine.key(record),
                   Contract.guard(record),
                   spec.id,
                   :dispatching,
                   [state: :verifying, receipt: receipt],
                   1102
                 ])

        result = %ExportResult{
          reference:
            ExportDestination.reference(spec.destination, "sha256:" <> receipt.manifest_sha256),
          manifest_sha256: receipt.manifest_sha256,
          size_bytes: receipt.size_bytes,
          platform: receipt.platform,
          architecture: "x86_64",
          config_sha256: proof.identity["config_sha256"],
          content_sha256: proof.identity["content_sha256"],
          runtime_version: "1.22.0",
          verified_at_ms: 1103
        }

        assert {:ok, published} =
                 Memory.machine(store, :export_advance, [
                   ManagedMachine.key(record),
                   Contract.guard(verifying),
                   spec.id,
                   :verifying,
                   [state: :published, result: result],
                   1103
                 ])

        published
      else
        record
      end

    epoch = String.duplicate("a", 32)

    peer =
      start_supervised!(
        {Peer,
         %{
           parent: self(),
           epoch: epoch,
           busy: options[:busy] || false,
           frozen: false,
           deleted: mode == :deleted,
           observed: stopped.observed_machine,
           reply: options[:reply] || :proof,
           delay_ms: options[:delay_ms] || 0
         }}
      )

    context = %EmbeddedContext{
      config: struct(Config),
      server: peer,
      pinned: true,
      epoch: if(options[:stale_epoch], do: String.duplicate("f", 32), else: epoch)
    }

    reference = %Reference{
      adapter: Adapter,
      kind: :embedded,
      id: record.worker_id,
      context: context,
      budget: %Budget{
        timeout_ms: options[:timeout_ms] || 1000,
        max_request_bytes: 1_048_576,
        max_response_bytes: 16384
      }
    }

    config = %{
      managed_machines: true,
      store: {Memory, store},
      workers: [%Target{kind: :embedded, id: record.worker_id, connection: reference}],
      owner: "owner",
      clock: Clock,
      lease_ms: 10000,
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

    {runtime, store, record, spec}
  end

  for mode <- [:unknown, :published, :deleted] do
    test "explicit #{mode} resolution fences the pinned owner and atomically consumes cleanup" do
      {runtime, store, record, spec} = fixture(unquote(mode))
      handle = {record.scope, record.id, spec.id}

      options = [
        quiesced: true,
        disposition: if(unquote(mode) == :deleted, do: :deleted, else: :stopped)
      ]

      assert {:ok, export} = Exports.resolve(runtime, handle, record.version, options)
      assert_receive {:quiesce, _}
      assert_receive {:cleanup, id, true}
      assert id == spec.id
      assert_receive {:inspect, true}

      assert export.state ==
               if(unquote(mode) == :published, do: :completed, else: :resolved_unknown)

      assert export.result == record.exports[spec.id].result
      assert export.receipt == record.exports[spec.id].receipt
      assert export.native_authority.cleanup.operation_id == id
      assert {:ok, usage} = Memory.usage(store, record.worker_id)
      assert usage.slots == if(unquote(mode) == :deleted, do: 0, else: 1)
      assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(record)])
      assert saved.created_machine == record.created_machine
      refute export.state == :completed and export.result == nil
    end
  end

  test "busy or stale pinned channels prevent cleanup and preserve reservations" do
    for options <- [[busy: true], [stale_epoch: true]] do
      {runtime, store, record, spec} = fixture(:unknown, options)

      assert {:error, _} =
               Exports.resolve(runtime, {record.scope, record.id, spec.id}, record.version,
                 quiesced: true
               )

      assert_receive {:quiesce, _}
      refute_receive {:cleanup, _, _}
      assert {:ok, %{slots: 2, disk_gb: 130}} = Memory.usage(store, record.worker_id)
      stop_supervised!(:model_runtime)
      stop_supervised!(Peer)
      stop_supervised!(Memory)
    end
  end

  test "cleanup and inspection share the original budget including fencing" do
    {runtime, store, record, spec} = fixture(:unknown, timeout_ms: 5, delay_ms: 15)

    assert {:error, %{category: :expired}} =
             Exports.resolve(runtime, {record.scope, record.id, spec.id}, record.version,
               quiesced: true
             )

    refute_receive {:inspect, _}
    assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(record)])
    assert saved.exports[spec.id] == record.exports[spec.id]
    assert {:ok, %{slots: 2, disk_gb: 130}} = Memory.usage(store, record.worker_id)
  end

  test "foreign or uncertain cleanup cannot release accounting or manufacture a result" do
    for reply <- [:foreign, :uncertain] do
      {runtime, store, record, spec} = fixture(:unknown, reply: reply)

      assert {:error, _} =
               Exports.resolve(runtime, {record.scope, record.id, spec.id}, record.version,
                 quiesced: true
               )

      assert_receive {:cleanup, _, true}
      assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(record)])
      assert saved.exports[spec.id] == record.exports[spec.id]
      assert {:ok, %{slots: 2, disk_gb: 130}} = Memory.usage(store, record.worker_id)
      stop_supervised!(:model_runtime)
      stop_supervised!(Peer)
      stop_supervised!(Memory)
    end
  end
end
