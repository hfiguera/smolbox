defmodule SmolBox.ManagedGuestFilesTest do
  use ExUnit.Case, async: true

  alias SmolBox.{
    Files,
    GuestPaths,
    Machines,
    ManagedMachineSpec,
    ManagedPeer,
    Runtime,
    RuntimeFixture
  }

  alias SmolBox.Store.Memory

  defmodule OldStore do
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
      {:ok, Map.delete(capabilities, :guest_files)}
    end
  end

  defp machine_spec(fixture) do
    ManagedMachineSpec.new(
      scope: fixture.spec.scope,
      id: "files",
      artifact: fixture.spec.artifact,
      profile: fixture.spec.profile
    )
  end

  test "managed transfers verify bytes, preserve policy through restart and retain the machine" do
    {:ok, paths} = GuestPaths.new(upload_roots: ["/app"], download_roots: ["/app"])
    fixture = RuntimeFixture.start(__MODULE__, guest_paths: paths, max_file_bytes: 2_097_152)
    bytes = :binary.copy(<<0, 255>>, 600_000)
    Agent.update(fixture.artifacts, &Map.put(&1, {"contract", "large"}, bytes))
    {:ok, spec} = machine_spec(fixture)
    {:ok, handle} = Machines.create(fixture.runtime, spec)
    {:ok, created} = Machines.await(fixture.runtime, handle, 5000)
    {:ok, _} = Machines.start(fixture.runtime, handle, created.version)
    {:ok, running} = Machines.await(fixture.runtime, handle, 5000)
    assert running.state == :running

    input = %{
      "source" => "large",
      "path" => "/app/input",
      "size" => byte_size(bytes),
      "sha256" => Files.sha256(bytes),
      "mode" => "runtime_default"
    }

    output = %{"destination" => "large", "path" => "/app/input", "max_bytes" => byte_size(bytes)}
    request = %{fixture.spec | inputs: [input], outputs: [output]}
    {:ok, execution} = Machines.submit(fixture.runtime, handle, request)

    assert {:ok, %{state: :completed, artifacts: [%{"sha256" => digest, "size" => size}]}} =
             SmolBox.await(fixture.runtime, execution, 5000)

    assert digest == Files.sha256(bytes) and size == byte_size(bytes)
    {:ok, idle} = Machines.await(fixture.runtime, handle, 5000)
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, fixture.options})
    assert {:ok, recovered} = Machines.inspect(runtime, handle)
    assert recovered.machine_name == idle.machine_name
    assert recovered.spec.profile == spec.profile
    assert {:ok, ^execution} = Machines.submit(runtime, handle, request)
    assert [_one] = ManagedPeer.snapshot(fixture.peer).commands
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
    # Removing approval prevents additional work without forgetting retained resources.
    stop_supervised!(Runtime)
    [worker] = fixture.options[:workers]

    runtime =
      start_supervised!(
        {Runtime,
         Keyword.put(fixture.options, :workers, [
           %{worker | profiles: [%{fixture.spec.profile | id: "revoked-policy"}]}
         ])}
      )

    before = ManagedPeer.snapshot(fixture.peer).operations
    {:ok, rejected} = Machines.submit(runtime, handle, %{request | id: "revoked"})

    assert {:ok, %{state: :failed, last_error: %{category: :unsupported_capability}}} =
             SmolBox.await(runtime, rejected, 5000)

    after_ops = ManagedPeer.snapshot(fixture.peer).operations

    assert Enum.count(before, fn {method, _} -> method == "PUT" end) ==
             Enum.count(after_ops, fn {method, _} -> method == "PUT" end)
  end

  test "legacy stores and older workers cannot admit new file policies" do
    {:ok, paths} = GuestPaths.new(upload_roots: ["/app"], download_roots: ["/app"])

    fixture =
      RuntimeFixture.start(__MODULE__,
        guest_paths: paths,
        runtime_version: "1.16.1",
        expected_runtime_version: "1.16.1"
      )

    {:ok, spec} = machine_spec(fixture)
    assert {:error, %{category: :unsupported_capability}} = Machines.create(fixture.runtime, spec)
    stop_supervised!(Runtime)

    runtime =
      start_supervised!(
        {Runtime, Keyword.put(fixture.options, :store, {OldStore, fixture.store})}
      )

    assert {:error, %{category: :unsupported_capability}} = Machines.create(runtime, spec)
    assert ManagedPeer.snapshot(fixture.peer).creations == []
  end
end
