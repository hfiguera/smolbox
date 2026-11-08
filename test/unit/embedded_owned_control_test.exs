Code.require_file("examples/embedded_port/lib/owned_control.ex")

defmodule SmolBox.EmbeddedOwnedControlTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedContext, Reference}

  alias SmolBox.Embedded.Config
  alias SmolBox.Example.EmbeddedOwnedControl

  alias SmolBox.Store.{Memory, NativeUnbootedBranchDisposalContract}

  alias SmolBox.{DiskExpansion, Error}

  defmodule StopPeer do
    def supports_operation?(_, :stop), do: true

    def invoke({observer, result}, :stop, [_name], _budget) do
      send(observer, :stop_entered)

      case result do
        {:delay, milliseconds, result} ->
          Process.sleep(milliseconds)
          result

        result ->
          result
      end
    end
  end

  defmodule QuiescencePeer do
    def quiesce(server, epoch, timeout) do
      Agent.get_and_update(server, fn {observer, [reply | rest]} ->
        send(observer, {:quiescence, epoch, timeout})
        {reply, {observer, if(rest == [], do: [reply], else: rest)}}
      end)
    end
  end

  defmodule HealthPeer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call(:health, _from, {observer, result} = state) do
      send(observer, :health_observed)
      {:reply, result, state}
    end
  end

  defp fixture(health) do
    # Typed store/transport peers only: no SDK owner, VM or native request.
    store = start_supervised!(Memory, id: make_ref())
    {record, _, _, _} = NativeUnbootedBranchDisposalContract.prepare(Memory, store, true)
    stopped = %{DiskExpansion.expected(record) | state: :stopped}
    observer = self()
    server = start_supervised!({HealthPeer, {observer, health}}, id: make_ref())

    context = %EmbeddedContext{
      server: server,
      epoch: "original-epoch",
      pinned: true,
      config:
        struct(Config,
          id: "original",
          domain_generation: "generation",
          package_identity: %{},
          package_manifest_sha256: String.duplicate("a", 64),
          bridge: :port,
          limits: %{cancel_grace_ms: 0}
        )
    }

    reference = %Reference{
      adapter: StopPeer,
      kind: :embedded,
      id: "original",
      context: {observer, {:ok, stopped}},
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 65_536, max_response_bytes: 65_536}
    }

    {record, stopped, reference, context}
  end

  defp healthy(epoch),
    do:
      {:ok,
       %{
         status: :ready,
         epoch: epoch,
         target_id: "original",
         generation: "generation",
         package_identity: %{},
         package_manifest_sha256: String.duplicate("a", 64)
       }}

  test "a health rejection after successful stop preserves whole-operation uncertainty" do
    busy =
      {:error,
       %Error{
         category: :admission_exhausted,
         operation: :embedded,
         evidence: :not_dispatched
       }}

    for observation <- [busy, healthy("different-epoch")] do
      {record, _, reference, context} = fixture(observation)

      assert {:error, %{operation: :stop, evidence: :dispatch_uncertain}} =
               EmbeddedOwnedControl.verify_stop(reference, record, context)

      assert_receive :stop_entered
      assert_receive :health_observed
      refute_receive :stop_entered, 0
    end
  end

  test "successful stop and same-owner health preserve the actual stopped observation" do
    {record, stopped, reference, context} = fixture(healthy("original-epoch"))
    assert {:ok, ^stopped} = EmbeddedOwnedControl.verify_stop(reference, record, context)
    assert_receive :stop_entered
    assert_receive :health_observed
  end

  test "a definitive stop rejection retains its evidence without subsequent health observation" do
    {record, _, reference, context} = fixture(healthy("original-epoch"))

    rejected =
      {:error,
       %Error{category: :admission_exhausted, operation: :stop, evidence: :not_dispatched}}

    reference = %{reference | context: {self(), rejected}}
    assert ^rejected = EmbeddedOwnedControl.verify_stop(reference, record, context)
    assert_receive :stop_entered
    refute_receive :health_observed, 0
  end

  test "quiescence waits under the original epoch and decreasing budget before stop dispatch" do
    observer = self()

    busy =
      {:error,
       %Error{category: :admission_exhausted, operation: :embedded, evidence: :not_dispatched}}

    server = start_supervised!({Agent, fn -> {observer, [busy, busy, :ok]} end})
    epoch = make_ref()

    assert :ok =
             EmbeddedOwnedControl.await_quiesced(
               QuiescencePeer,
               server,
               epoch,
               System.monotonic_time(:millisecond) + 1000
             )

    assert_receive {:quiescence, ^epoch, first}
    assert_receive {:quiescence, ^epoch, second}
    assert_receive {:quiescence, ^epoch, third}
    assert first <= 1000 and first >= second and second >= third and third > 0
    refute_receive {:quiescence, _, _}, 0
    refute_receive :stop_entered, 0
  end

  test "uncertain or expired quiescence cannot retry or enter stop" do
    observer = self()

    uncertain =
      {:error,
       %Error{category: :admission_exhausted, operation: :embedded, evidence: :dispatch_uncertain}}

    server = start_supervised!({Agent, fn -> {observer, [uncertain]} end})
    epoch = make_ref()
    deadline = System.monotonic_time(:millisecond) + 1000

    assert ^uncertain =
             EmbeddedOwnedControl.await_quiesced(QuiescencePeer, server, epoch, deadline)

    assert_receive {:quiescence, ^epoch, _}
    refute_receive {:quiescence, _, _}, 0

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             EmbeddedOwnedControl.await_quiesced(
               QuiescencePeer,
               server,
               epoch,
               System.monotonic_time(:millisecond) - 1
             )

    refute_receive {:quiescence, _, _}, 0
    refute_receive :stop_entered, 0
  end

  test "a stop that returns after the captured deadline remains uncertain without renewed health time" do
    {record, stopped, reference, context} = fixture(healthy("original-epoch"))
    reference = %{reference | context: {self(), {:delay, 250, {:ok, stopped}}}}

    assert {:error, %{operation: :stop, evidence: :dispatch_uncertain}} =
             EmbeddedOwnedControl.verify_stop(
               reference,
               record,
               context,
               System.monotonic_time(:millisecond) + 200
             )

    assert_receive :stop_entered
    refute_receive :health_observed, 0
    refute_receive :stop_entered, 0
  end

  test "expired stop cannot dispatch or inspect health" do
    {record, _, reference, context} = fixture(healthy("original-epoch"))

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             EmbeddedOwnedControl.verify_stop(
               reference,
               record,
               context,
               System.monotonic_time(:millisecond) - 1
             )

    refute_receive :stop_entered, 0
    refute_receive :health_observed, 0
  end

  test "continuously busy quiescence cannot renew the stop deadline" do
    observer = self()

    busy =
      {:error,
       %Error{category: :admission_exhausted, operation: :embedded, evidence: :not_dispatched}}

    server = start_supervised!({Agent, fn -> {observer, [busy]} end})
    entered = System.monotonic_time(:millisecond)

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             EmbeddedOwnedControl.await_quiesced(QuiescencePeer, server, :original, entered + 50)

    assert System.monotonic_time(:millisecond) - entered < 1000
    refute_receive :stop_entered, 0
  end
end
