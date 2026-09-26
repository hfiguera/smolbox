defmodule SmolBox.ManagedRegistryTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machines, ManagedMachineSpec, ManagedPeer, RegistryCredentials, RuntimeFixture}
  alias SmolBox.Store.{Codec, Memory, SourceContract}

  defmodule Credentials do
    @behaviour RegistryCredentials
    @impl true
    def fetch(agent, "registry-reader"), do: Agent.get(agent, & &1)
  end

  for {event, phase, expected, warms} <- [
        {:source_preparing, :before, :created, 1},
        {:source_preparing, :after, :missing, 0},
        {:source_prepared, :before, :missing, 1},
        {:source_prepared, :after, :created, 1}
      ] do
    test "interruption at #{event}/#{phase} resumes only durable safe preparation" do
      observer = self()
      event = unquote(event)
      phase = unquote(phase)

      gate =
        start_supervised!(
          {Agent,
           fn ->
             %{event: event, phase: phase, observer: observer, fired: false}
           end},
          id: :source_gate
        )

      {fixture, _} = fixture(faults: gate)
      {:ok, handle} = Machines.create(fixture.runtime, spec(fixture))
      assert_receive {:boundary, ^event, ^phase, _blocked}, 5000
      stop_supervised!(SmolBox.Runtime)
      runtime = start_supervised!({SmolBox.Runtime, fixture.options})
      assert {:ok, %{state: unquote(expected)}} = Machines.await(runtime, handle, 5000)
      assert count(fixture.peer, "POST", "/artifacts/warm") == unquote(warms)

      assert count(fixture.peer, "POST", "/api/v1/machines") ==
               if(unquote(expected) == :created, do: 1, else: 0)
    end
  end

  test "approved registry machine persists preparation and reconnects after controller restart" do
    {fixture, credentials} = fixture()
    {:ok, handle} = Machines.create(fixture.runtime, spec(fixture))
    assert {:ok, %{state: :created} = created} = Machines.await(fixture.runtime, handle, 5000)
    assert created.preparation.content_sha256 == SourceContract.source().content_sha256
    assert created.spec.artifact["credential_ref"] == "registry-reader"
    assert {:ok, bytes} = Codec.encode(created)
    assert {:ok, ^created} = Codec.decode(bytes)
    refute bytes =~ "first-token"
    assert count(fixture.peer, "POST", "/artifacts/warm") == 1

    assert [%{"registryIdentityToken" => "first-token"}] =
             ManagedPeer.snapshot(fixture.peer).creations

    assert {:ok, ^handle} = Machines.create(fixture.runtime, created.spec)

    assert {:ok, _} =
             Machines.start(
               fixture.runtime,
               handle,
               RuntimeFixture.await_idle(fixture.runtime, handle).version
             )

    assert {:ok, %{state: :running}} = Machines.await(fixture.runtime, handle, 5000)
    Agent.update(credentials, fn _ -> {:ok, "rotated-token"} end)
    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, fixture.options})
    assert {:ok, recovered} = Machines.inspect(runtime, handle)
    assert recovered.machine_name == created.machine_name
    assert recovered.preparation == created.preparation
    assert recovered.spec == created.spec
    assert {:ok, execution} = Machines.submit(runtime, handle, fixture.spec)
    assert {:ok, %{state: :completed}} = SmolBox.await(runtime, execution, 5000)
    idle = RuntimeFixture.await_idle(runtime, handle)
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
    assert {:ok, _} = Machines.delete(runtime, handle, idle.version)

    assert {:ok, %{state: :deleted, reservation: nil, preparation: preparation}} =
             Machines.await(runtime, handle, 5000)

    assert preparation == created.preparation
    assert {:ok, %{slots: 0}} = Memory.usage(fixture.store, "peer")
    assert count(fixture.peer, "POST", "/artifacts/warm") == 1
  end

  test "lost preparation does not create, replay, or allow another cold preparation" do
    {fixture, _credentials} = fixture(warm_lost: true, slots: 2)
    {:ok, first} = Machines.create(fixture.runtime, spec(fixture))

    assert {:ok, %{state: :unknown, phase: :uncertain, preparation: nil}} =
             Machines.await(fixture.runtime, first, 5000)

    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, fixture.options})
    {:ok, second} = Machines.create(runtime, %{spec(fixture) | id: "second"})
    assert {:error, %{category: :expired}} = Machines.await(runtime, second, 300)
    assert {:ok, %{state: :accepted, worker_id: nil}} = Machines.inspect(runtime, second)
    assert count(fixture.peer, "POST", "/artifacts/warm") == 1
    assert count(fixture.peer, "POST", "/api/v1/machines") == 0
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
  end

  test "lost create retains the verified preparation but never adopts by name" do
    {fixture, _credentials} = fixture(create_lost: true)
    {:ok, handle} = Machines.create(fixture.runtime, spec(fixture))

    assert {:ok, %{state: :unknown, created_machine: nil, preparation: preparation}} =
             Machines.await(fixture.runtime, handle, 5000)

    assert preparation.content_sha256 == SourceContract.source().content_sha256
    assert map_size(ManagedPeer.snapshot(fixture.peer).machines) == 1
    assert {:error, _} = Machines.submit(fixture.runtime, handle, fixture.spec)
    assert count(fixture.peer, "POST", "/api/v1/machines") == 1
  end

  test "credential failures cannot reach machine creation" do
    {fixture, credentials} = fixture()
    Agent.update(credentials, fn _ -> {:error, "secret-resolver-failure"} end)
    {:ok, handle} = Machines.create(fixture.runtime, spec(fixture))

    assert {:ok, %{state: :unknown, last_error: %{category: :authentication}} = record} =
             Machines.await(fixture.runtime, handle, 5000)

    assert count(fixture.peer, "POST", "/artifacts/warm") == 0
    assert count(fixture.peer, "POST", "/api/v1/machines") == 0
    {:ok, bytes} = Codec.encode(record)
    refute bytes =~ "secret-resolver-failure"
    assert record.last_error.evidence == :not_dispatched
  end

  test "credential rotation between preparation and creation uses the current token" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn ->
           %{event: :source_prepared, phase: :after, observer: observer, fired: false}
         end},
        id: :rotation_gate
      )

    {fixture, credentials} = fixture(faults: gate)
    {:ok, handle} = Machines.create(fixture.runtime, spec(fixture))
    assert_receive {:boundary, :source_prepared, :after, blocked}, 5000
    Agent.update(credentials, fn _ -> {:ok, "rotated-token"} end)
    send(blocked, :release_boundary)
    assert {:ok, %{state: :created} = created} = Machines.await(fixture.runtime, handle, 5000)

    assert [%{"registryIdentityToken" => "rotated-token"}] =
             ManagedPeer.snapshot(fixture.peer).creations

    assert {:ok, bytes} = Codec.encode(created)
    refute bytes =~ "rotated-token"
    assert created.spec.artifact == spec(fixture).artifact
  end

  test "a mismatched preparation digest never reaches creation or releases capacity" do
    {fixture, _} = fixture(warm_digest: String.duplicate("f", 64))
    {:ok, handle} = Machines.create(fixture.runtime, spec(fixture))

    assert {:ok, %{state: :unknown, preparation: nil}} =
             Machines.await(fixture.runtime, handle, 5000)

    assert count(fixture.peer, "POST", "/api/v1/machines") == 0
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
  end

  test "unapproved identity and disposable remote submission fail before acceptance" do
    {fixture, _credentials} = fixture()
    original = spec(fixture)
    changed = put_in(original.artifact["content_sha256"], String.duplicate("c", 64))

    assert {:error, %{category: :unsupported_capability}} =
             Machines.create(fixture.runtime, changed)

    assert {:error, %{category: :unsupported_capability}} =
             SmolBox.submit(fixture.runtime, fixture.spec)

    assert {:ok, %{slots: 0}} = Memory.usage(fixture.store, "peer")
    assert count(fixture.peer, "POST", "/artifacts/warm") == 0
  end

  defp fixture(options \\ []) do
    credentials = start_supervised!({Agent, fn -> {:ok, "first-token"} end}, id: :credentials)

    fixture =
      RuntimeFixture.start(
        __MODULE__,
        [source: SourceContract.source(), registry_credentials: {Credentials, credentials}] ++
          options
      )

    {fixture, credentials}
  end

  defp spec(fixture) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: fixture.spec.scope,
        id: "computer",
        artifact: fixture.spec.artifact,
        profile: fixture.spec.profile
      )

    spec
  end

  defp count(peer, method, path),
    do: Enum.count(ManagedPeer.snapshot(peer).operations, &(&1 == {method, path}))
end
