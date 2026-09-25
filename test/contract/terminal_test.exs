defmodule SmolBox.TerminalTest do
  use ExUnit.Case, async: true

  alias SmolBox.{
    Client,
    Error,
    Machines,
    ManagedMachineSpec,
    ManagedPeer,
    RuntimeFixture,
    Terminal
  }

  alias SmolBox.Store.Codec
  alias SmolBox.Terminal.{Result, Spec}

  defmodule PreviousStore do
    @moduledoc false
    alias SmolBox.Store.Memory

    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(arguments)),
        do: apply(Memory, unquote(operation), [unquote_splicing(arguments)])
    end

    def capabilities(store) do
      {:ok, capabilities} = Memory.capabilities(store)
      {:ok, Map.delete(capabilities, :interactive_terminal)}
    end
  end

  defmodule FailingResultStore do
    @moduledoc false
    alias SmolBox.Store.Memory

    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks), operation != :write do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(arguments)),
        do: apply(Memory, unquote(operation), [unquote_splicing(arguments)])
    end

    def write(store, key, guard, changes, now) do
      if Keyword.has_key?(changes, :result),
        do: {:error, %SmolBox.Error{category: :store, operation: :store}},
        else: Memory.write(store, key, guard, changes, now)
    end
  end

  test "managed terminal preserves bytes, resizes, confirms exit and releases only the command slot" do
    f = RuntimeFixture.start(__MODULE__, test_pid: self())
    {machine, _running} = machine(f)
    spec = spec(f)
    assert {:ok, key} = Terminal.open(f.runtime, machine, spec)
    assert {:ok, ^key} = Terminal.open(f.runtime, machine, spec)
    assert {:ok, terminal} = Terminal.attach(f.runtime, key)
    assert {:ok, {:output, "ready\r\n"}} = Terminal.next(terminal)
    assert :ok = Terminal.input(terminal, <<0, 255, 128>>)
    assert {:ok, {:output, <<0, 255, 128>>}} = Terminal.next(terminal)
    assert :ok = Terminal.resize(terminal, 100, 40)
    assert {:ok, {:output, size}} = Terminal.next(terminal)
    assert Jason.decode!(size) == %{"type" => "resize", "cols" => 100, "rows" => 40}
    assert :ok = Terminal.input(terminal, "exit")
    assert {:ok, {:closed, {:ok, %Result{exit_code: 7}}}} = Terminal.next(terminal)

    assert {:ok, %{state: :completed, result: %Result{exit_code: 7}} = record} =
             SmolBox.await(f.runtime, key, 5000)

    assert {:ok, encoded} = Codec.encode(record)
    assert String.starts_with?(encoded, "smolbox-record-v7")
    assert {:ok, ^record} = Codec.decode(encoded)
    <<"smolbox-record-v7", payload::binary>> = encoded
    assert {:error, %{category: :store}} = Codec.decode("smolbox-record-v6" <> payload)

    assert {:ok, %{active_execution: nil, reservation: %{slots: 1}}} =
             Machines.await(f.runtime, machine, 5000)

    assert {:ok, ^key} = Terminal.open(f.runtime, machine, spec)
    assert [_] = ManagedPeer.snapshot(f.peer).commands
    refute :binary.match(encoded, <<0, 255, 128>>) != :nomatch
  end

  for action <- ["sentinel", "lost"] do
    @action action
    test "#{action} stays unknown and blocks managed operations" do
      f = RuntimeFixture.start(__MODULE__)
      {machine, _running} = machine(f)
      assert {:ok, key} = Terminal.open(f.runtime, machine, spec(f))
      assert {:ok, terminal} = Terminal.attach(f.runtime, key)
      assert :ok = Terminal.input(terminal, @action)
      assert {:ok, %{state: :unknown, result: nil}} = SmolBox.await(f.runtime, key, 5000)
      {:ok, busy} = Machines.inspect(f.runtime, machine)

      assert {:error, %Error{category: :admission_exhausted}} =
               Machines.stop(f.runtime, machine, busy.version)

      assert {:error, %Error{category: :admission_exhausted}} =
               Machines.delete(f.runtime, machine, busy.version)

      assert {:error, %Error{category: :admission_exhausted}} =
               Machines.submit(f.runtime, machine, %{f.spec | id: "next"})
    end
  end

  test "low level session is consumer-bound and slow consumers have bounded buffering" do
    f = RuntimeFixture.start(__MODULE__)
    {_machine, running} = machine(f)
    {:ok, terminal_spec} = Spec.new(max_buffer_bytes: 1024)
    client = hd(f.options[:workers]).client
    assert {:ok, terminal} = Client.open_terminal(client, running.machine_name, terminal_spec)
    result = Task.async(fn -> Terminal.input(terminal, "unauthorized") end) |> Task.await()
    assert {:error, %Error{category: :authentication}} = result
    assert :ok = Terminal.input(terminal, "noise")
    assert {:ok, {:output, _ready}} = Terminal.next(terminal)
    assert {:ok, {:closed, {:error, %Error{category: :output_limit}}}} = Terminal.next(terminal)
  end

  for {event, phase, expected} <- [
        {:dispatch_intent, :after, :unknown},
        {:terminal_open, :after, :unknown},
        {:result_write, :before, :unknown},
        {:result_write, :after, :completed}
      ] do
    @event event
    @phase phase
    @expected expected
    test "restart at #{@event}/#{@phase} preserves #{@expected} and never replays a terminal" do
      observer = self()

      gate =
        start_supervised!(
          {Agent, fn -> %{event: @event, phase: @phase, fired: false, observer: observer} end},
          id: :gate
        )

      f = RuntimeFixture.start(__MODULE__, faults: gate)
      {machine, _} = machine(f)
      intent = spec(f)
      {:ok, key} = Terminal.open(f.runtime, machine, intent)

      if @event == :result_write do
        {:ok, terminal} = Terminal.attach(f.runtime, key)
        assert :ok = Terminal.input(terminal, "exit")
      end

      event = @event
      phase = @phase
      assert_receive {:boundary, ^event, ^phase, blocked}, 5000
      stop_supervised!(SmolBox.Runtime)
      send(blocked, :release_boundary)
      runtime = start_supervised!({SmolBox.Runtime, f.options})
      expected = @expected
      assert {:ok, %{state: ^expected} = recovered} = SmolBox.await(runtime, key, 5000)
      before = ManagedPeer.snapshot(f.peer).commands
      assert {:ok, ^key} = Terminal.open(runtime, machine, intent)
      assert ManagedPeer.snapshot(f.peer).commands == before
      assert {:error, %Error{category: :unknown}} = Terminal.attach(runtime, key, 0)

      assert_recovery(f, runtime, machine, recovered)
    end
  end

  test "another controller cannot attach, overlap commands or race stop/delete; cancellation is uncertain" do
    f = RuntimeFixture.start(__MODULE__)
    {machine, _} = machine(f)
    {:ok, key} = Terminal.open(f.runtime, machine, spec(f))
    {:ok, terminal} = Terminal.attach(f.runtime, key)

    other =
      start_supervised!(
        {SmolBox.Runtime, Keyword.put(f.options, :name, SmolBox.OtherTerminalRuntime)},
        id: :other
      )

    assert {:ok, ^key} = Terminal.open(other, machine, spec(f))
    assert {:error, %Error{category: :expired}} = Terminal.attach(other, key, 0)

    assert {:error, %Error{category: :identity_conflict}} =
             Terminal.open(other, machine, %{spec(f) | command: %{spec(f).command | cols: 81}})

    {:ok, busy} = Machines.inspect(other, machine)

    for operation <- [:stop, :delete] do
      assert {:error, %Error{category: :admission_exhausted}} =
               apply(Machines, operation, [other, machine, busy.version])
    end

    assert {:error, %Error{category: :admission_exhausted}} =
             Machines.submit(other, machine, %{f.spec | id: "other"})

    assert {:ok, _} = SmolBox.cancel(other, elem(key, 0), elem(key, 1))
    assert {:ok, %{state: :unknown}} = SmolBox.await(other, key, 5000)
    assert :ok = Terminal.close(terminal)
  end

  test "ownership mismatch and disposable submissions never open an interactive connection" do
    f = RuntimeFixture.start(__MODULE__)
    {machine, running} = machine(f)
    intent = spec(f)
    assert {:error, %Error{category: :unsupported_capability}} = SmolBox.submit(f.runtime, intent)

    Agent.update(
      f.peer,
      &update_in(&1.machines[running.machine_name]["createdAt"], fn n -> n + 1 end)
    )

    assert {:ok, key} = Terminal.open(f.runtime, machine, intent)

    assert {:ok, %{state: :failed, evidence: :not_dispatched}} =
             SmolBox.await(f.runtime, key, 5000)

    assert ManagedPeer.snapshot(f.peer).commands == []
  end

  test "consumer disappearance closes observation and preserves unknown durable outcome" do
    f = RuntimeFixture.start(__MODULE__)
    {machine, _} = machine(f)
    {:ok, key} = Terminal.open(f.runtime, machine, spec(f))
    parent = self()

    consumer =
      spawn(fn ->
        {:ok, terminal} = Terminal.attach(f.runtime, key)
        send(parent, {:attached, terminal})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:attached, terminal}, 5000
    send(consumer, :finish)

    assert {:ok, %{state: :unknown, last_error: %{operation: :terminal_consumer}}} =
             SmolBox.await(f.runtime, key, 5000)

    refute Process.alive?(terminal.pid)
  end

  test "terminal capability absence and unavailable stores reject before opening" do
    f = RuntimeFixture.start(__MODULE__)
    {machine, _} = machine(f)
    stop_supervised!(SmolBox.Runtime)
    options = Keyword.put(f.options, :store, {PreviousStore, f.store})
    runtime = start_supervised!({SmolBox.Runtime, options})

    assert {:error, %{category: :unsupported_capability}} =
             Terminal.open(runtime, machine, spec(f))

    stop_supervised!(SmolBox.Store.Memory)
    assert {:error, %{category: :store}} = Terminal.open(runtime, machine, spec(f))
    assert ManagedPeer.snapshot(f.peer).commands == []
  end

  test "failure to persist a live exit cannot release the slot or replay the terminal" do
    f = RuntimeFixture.start(__MODULE__)
    {machine, _} = machine(f)
    stop_supervised!(SmolBox.Runtime)
    options = Keyword.put(f.options, :store, {FailingResultStore, f.store})
    runtime = start_supervised!({SmolBox.Runtime, options})
    {:ok, key} = Terminal.open(runtime, machine, spec(f))
    {:ok, live} = Terminal.attach(runtime, key)
    :ok = Terminal.input(live, "exit")
    assert {:ok, {:output, _}} = Terminal.next(live)
    assert {:ok, {:closed, {:ok, %Result{exit_code: 7}}}} = Terminal.next(live)
    assert {:ok, %{state: :unknown, result: nil}} = SmolBox.await(runtime, key, 5000)
    assert {:ok, %{active_execution: ^key}} = Machines.await(runtime, machine, 5000)
    assert {:ok, ^key} = Terminal.open(runtime, machine, spec(f))
    assert [_] = ManagedPeer.snapshot(f.peer).commands
  end

  test "cancelling before dispatch intent commits never opens the PTY" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn ->
           %{event: :dispatch_intent, phase: :before, fired: false, observer: observer}
         end},
        id: :gate
      )

    f = RuntimeFixture.start(__MODULE__, faults: gate)
    {machine, _} = machine(f)
    {:ok, key} = Terminal.open(f.runtime, machine, spec(f))
    assert_receive {:boundary, :dispatch_intent, :before, blocked}, 5000
    assert {:ok, _} = SmolBox.cancel(f.runtime, elem(key, 0), elem(key, 1))
    send(blocked, :release_boundary)

    assert {:ok, %{state: :cancelled, evidence: :not_dispatched}} =
             SmolBox.await(f.runtime, key, 5000)

    assert {:ok, %{active_execution: nil, reservation: %{slots: 1}}} =
             Machines.await(f.runtime, machine, 5000)

    assert ManagedPeer.snapshot(f.peer).commands == []
  end

  test "an unclaimed terminal expires without releasing its uncertain slot" do
    f = RuntimeFixture.start(__MODULE__)
    {machine, _} = machine(f)
    intent = spec(f)

    {:ok, key} =
      Terminal.open(f.runtime, machine, %{intent | command: %{intent.command | attach_ms: 100}})

    assert {:ok, %{state: :unknown, last_error: %{operation: :terminal_consumer}}} =
             SmolBox.await(f.runtime, key, 5000)

    assert {:ok, %{active_execution: ^key}} = Machines.await(f.runtime, machine, 5000)
  end

  test "managed overall deadline preserves its cause and keeps the slot" do
    f = RuntimeFixture.start(__MODULE__)
    {machine, _} = machine(f)
    intent = spec(f)
    intent = %{intent | command: %{intent.command | session_ms: 1000, idle_ms: 1000}}
    {:ok, key} = Terminal.open(f.runtime, machine, intent)
    {:ok, live} = Terminal.attach(f.runtime, key)
    assert {:ok, {:output, _}} = Terminal.next(live)

    assert {:ok, {:closed, {:error, %{category: :expired, operation: :terminal_session}}}} =
             Terminal.next(live, 3000)

    assert {:ok,
            %{state: :unknown, last_error: %{category: :expired, operation: :terminal_session}}} =
             SmolBox.await(f.runtime, key, 5000)

    assert {:ok, %{active_execution: ^key}} = Machines.await(f.runtime, machine, 5000)
  end

  test "sequential terminals retain ports and retire old closed buffers under runtime capacity" do
    f = RuntimeFixture.start(__MODULE__, max_active: 1)
    runtime = f.runtime
    {machine, _} = machine(f, [%SmolBox.PortMapping{host: 28_731, guest: 8000}])
    {:ok, first} = Terminal.open(runtime, machine, spec(f))
    {:ok, old} = Terminal.attach(runtime, first)
    :ok = Terminal.input(old, "exit")
    assert {:ok, %{state: :completed}} = SmolBox.await(runtime, first, 5000)

    assert {:ok, %{active_execution: nil, reserved_ports: [28_731]}} =
             Machines.await(runtime, machine, 5000)

    assert Process.alive?(old.pid)
    monitor = Process.monitor(old.pid)
    {:ok, second} = Terminal.open(runtime, machine, %{spec(f) | id: "second"})
    {:ok, live} = Terminal.attach(runtime, second)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5000
    assert :ok = Terminal.input(live, "exit")
    assert {:ok, %{state: :completed}} = SmolBox.await(runtime, second, 5000)
    {:ok, idle} = Machines.await(runtime, machine, 5000)
    assert idle.reserved_ports == [28_731] and idle.reservation.slots == 1
    assert {:ok, _} = Machines.delete(runtime, machine, idle.version)

    assert {:ok, %{state: :deleted, reserved_ports: [], reservation: nil}} =
             Machines.await(runtime, machine, 5000)

    assert {:ok, ^first} = Terminal.open(runtime, machine, spec(f))
  end

  defp assert_recovery(f, runtime, machine, %{state: :unknown, result: nil}) do
    {:ok, unknown} = Machines.await(runtime, machine, 5000)
    Agent.update(f.peer, &put_in(&1.machines[unknown.machine_name]["state"], "stopped"))

    assert {:ok, %{active_execution: nil, state: :stopped}} =
             Machines.resolve(runtime, machine, unknown.version, quiesced: true)
  end

  defp assert_recovery(_f, _runtime, _machine, recovered),
    do: assert(recovered.result == %Result{exit_code: 7})

  defp machine(f, ports \\ []) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: f.spec.scope,
        id: "terminal-machine",
        artifact: f.spec.artifact,
        profile: f.spec.profile,
        ports: ports
      )

    {:ok, key} = Machines.create(f.runtime, spec)
    {:ok, created} = Machines.await(f.runtime, key, 5000)
    {:ok, _} = Machines.start(f.runtime, key, created.version)
    {:ok, running} = Machines.await(f.runtime, key, 5000)
    assert running.state == :running
    {key, running}
  end

  defp spec(f) do
    {:ok, terminal} =
      Spec.new(
        session_ms: 5000,
        idle_ms: 5000,
        max_buffer_bytes: min(f.spec.profile.max_output_bytes, 262_144)
      )

    %{f.spec | id: "terminal", command: terminal, inputs: [], outputs: []}
  end
end
