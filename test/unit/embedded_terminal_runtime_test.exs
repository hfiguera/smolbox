defmodule SmolBox.EmbeddedTerminalRuntimeTest do
  use ExUnit.Case, async: false
  alias SmolBox.Embedded.{Port, SDKIdentity}
  alias SmolBox.{ExecutionSpec, Machines, ManagedMachineSpec, Runtime, Terminal, TestArtifacts}
  alias SmolBox.Runtime.Config, as: RuntimeConfig
  alias SmolBox.Store.{Codec, Memory}
  alias SmolBox.Terminal.{Result, Spec}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  defmodule NoTerminalReader do
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(operation)(store, unquote_splicing(args)),
        do: apply(Memory, unquote(operation), [store, unquote_splicing(args)])
    end

    def capabilities(store) do
      {:ok, caps} = Memory.capabilities(store)
      {:ok, Map.delete(caps, :native_terminal_sessions)}
    end
  end

  setup context do
    sdk =
      SDKIdentity.implemented(
        "1.22.0",
        "9f446ae00219148ca4a703914f44a8e2fab11655"
      )

    sdk =
      if context[:terminal_preflight],
        do: put_in(sdk, ["feature_versions", "terminal_preflight"], 1),
        else: sdk

    native =
      Package.create(
        protocol_major: 2,
        backend: true,
        persistent_backend: true,
        sdk_identity: sdk
      )

    native = %{native | budget: %{native.budget | max_response_bytes: 4096}}
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{} end})

    options = [
      name: __MODULE__,
      namespace: "tty",
      mode: :ephemeral,
      store: {Memory, store},
      artifact_store: {TestArtifacts, artifacts},
      fingerprint_key: String.duplicate("k", 32),
      workers: [native],
      lease_ms: 1000,
      poll_ms: 20
    ]

    %{native: native, store: store, options: options}
  end

  @tag terminal_preflight: true
  test "public terminal preserves binary credit resize Exit and durable machine accounting",
       context do
    runtime = runtime(context.options)
    {machine, running} = machine(runtime, context.native)
    spec = spec(running)
    assert {:ok, key} = Terminal.open(runtime, machine, spec)
    assert {:ok, ^key} = Terminal.open(runtime, machine, spec)
    assert {:ok, terminal} = Terminal.attach(runtime, key)
    assert {:ok, ^terminal} = Terminal.attach(runtime, key)

    assert {:error, %{category: :authentication}} =
             Task.async(fn -> Terminal.input(terminal, "foreign") end) |> Task.await()

    assert {:ok, {:output, "ready\r\n"}} = Terminal.next(terminal)
    operations = requests(context.native) |> Enum.map(& &1["operation"])

    assert Enum.find_index(operations, &(&1 == "terminal_preflight")) <
             Enum.find_index(operations, &(&1 == "terminal_open"))

    assert :ok = Terminal.input(terminal, <<0, 255, 128>>)
    assert {:ok, {:output, <<0, 255, 128>>}} = Terminal.next(terminal)
    assert :ok = Terminal.resize(terminal, 120, 43)
    assert {:ok, {:output, dimensions}} = Terminal.next(terminal)
    assert Jason.decode!(dimensions) == %{"cols" => 120, "rows" => 43}
    bytes = :binary.copy(<<255>>, 512)

    for _ <- 1..50 do
      assert :ok = Terminal.input(terminal, bytes)
      assert {:ok, {:output, ^bytes}} = Terminal.next(terminal)
    end

    assert :ok = Terminal.input(terminal, "exit")
    assert {:ok, {:closed, {:ok, %Result{exit_code: 7}}}} = Terminal.next(terminal)

    assert {:ok, %{state: :completed, result: %Result{exit_code: 7}} = record} =
             SmolBox.await(runtime, key, 5000)

    assert record.backend_assignment == running.backend_assignment
    assert record.reservation == nil
    assert {:ok, <<"smolbox-record-v17\0", _::binary>> = encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)
    refute :binary.match(encoded, bytes) != :nomatch
    await(fn -> match?({:ok, %{active_execution: nil}}, Machines.inspect(runtime, machine)) end)
    assert {:ok, %{reservation: reservation}} = Machines.inspect(runtime, machine)
    assert reservation == running.reservation
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
    assert Enum.count(requests(context.native), &(&1["operation"] == "terminal_open")) == 1
    assert {:ok, ^key} = Terminal.open(runtime, machine, spec)
    assert {:ok, %{status: :ready}} = Port.health(:global.whereis_name({Port, node()}))
  end

  test "uncertain terminal remains unreplayable through normal stopped Runtime replacement",
       context do
    runtime = runtime(context.options)
    {machine, _running} = machine(runtime, context.native)
    spec = spec(elem(Machines.inspect(runtime, machine), 1))
    {:ok, key} = Terminal.open(runtime, machine, spec)
    {:ok, terminal} = Terminal.attach(runtime, key)
    assert {:ok, {:output, "ready\r\n"}} = Terminal.next(terminal)
    assert :ok = Terminal.input(terminal, "unknown")
    assert {:ok, {:closed, {:error, %{evidence: :unknown}}}} = Terminal.next(terminal)
    assert {:ok, %{state: :unknown, result: nil}} = SmolBox.await(runtime, key, 5000)

    await(fn ->
      match?(
        {:ok, %{state: :unknown, active_execution: ^key}},
        Machines.inspect(runtime, machine)
      )
    end)

    {:ok, held} = Machines.inspect(runtime, machine)

    assert {:error, %{category: :admission_exhausted}} =
             Machines.stop(runtime, machine, held.version)

    assert :ok = SmolBox.drain_worker(runtime, context.native.id)
    stop_supervised!({Runtime, __MODULE__})
    replacement = runtime(context.options, :draining)

    assert {:ok, %{state: :unknown, result: nil}} =
             SmolBox.fetch(replacement, elem(key, 0), elem(key, 1))

    assert {:error, %{category: :unknown}} = Terminal.attach(replacement, key, 0)
    assert {:ok, ^key} = Terminal.open(replacement, machine, spec)
    assert Enum.count(requests(context.native), &(&1["operation"] == "terminal_open")) == 1
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  test "native reader gate prevents startup before enrollment or helper launch", context do
    options = Keyword.put(context.options, :store, {NoTerminalReader, context.store})
    assert {:error, %{category: :unsupported_capability}} = RuntimeConfig.new(options)
    assert Package.received(context.native) == []
    assert {:ok, [], nil} = Memory.backend_assignments(context.store, context.native.id, nil, 10)
  end

  test "explicit API cancellation preserves uncertainty and the retained command slot", context do
    runtime = runtime(context.options)
    {machine, running} = machine(runtime, context.native)
    {:ok, key} = Terminal.open(runtime, machine, spec(running))
    {:ok, terminal} = Terminal.attach(runtime, key)
    assert {:ok, {:output, "ready\r\n"}} = Terminal.next(terminal)
    assert {:ok, _} = SmolBox.cancel(runtime, elem(key, 0), elem(key, 1))
    assert {:ok, {:closed, {:error, %{evidence: :unknown}}}} = Terminal.next(terminal)
    assert {:ok, %{state: :unknown, result: nil}} = SmolBox.await(runtime, key, 5000)

    await(fn ->
      match?(
        {:ok, %{state: :unknown, active_execution: ^key}},
        Machines.inspect(runtime, machine)
      )
    end)

    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
    assert Enum.count(requests(context.native), &(&1["operation"] == "terminal_open")) == 1
  end

  defp machine(runtime, native) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "native-terminal",
        id: "vm",
        profile: hd(native.profiles),
        artifact: hd(native.artifacts) |> Map.take(~w(id sha256 architecture))
      )

    {:ok, handle} = Machines.create(runtime, spec)
    {:ok, %{state: :stopped} = stopped} = Machines.await(runtime, handle, 5000)
    {:ok, _} = Machines.start(runtime, handle, stopped.version)
    {:ok, %{state: :running} = running} = Machines.await(runtime, handle, 5000)
    {handle, running}
  end

  defp spec(machine) do
    {:ok, terminal} =
      Spec.new(session_ms: 5000, idle_ms: 5000, max_buffer_bytes: 1024, max_input_bytes: 1024)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: machine.scope,
        id: "tty",
        profile: machine.spec.profile,
        artifact: machine.spec.artifact,
        command: terminal
      )

    spec
  end

  defp runtime(options, status \\ :ready) do
    runtime = start_supervised!(SmolBox.child_spec(options))
    await(fn -> match?({:ok, [%{status: ^status}]}, SmolBox.workers(runtime)) end)

    await(fn ->
      match?({:ok, %{status: :ready}}, Port.health(:global.whereis_name({Port, node()})))
    end)

    runtime
  end

  defp requests(native),
    do:
      for(
        message <- Package.received(native),
        message["type"] == "request",
        do: message["operation"]
      )

  defp await(check, attempts \\ 200)
  defp await(_check, 0), do: flunk("terminal fixture did not settle")

  defp await(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          await(check, attempts - 1)
        )
  end
end
