defmodule SmolBox.ManagedImagesTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machines, ManagedMachineSpec, ManagedPeer, Runtime, RuntimeFixture, Source}
  alias SmolBox.Store.{Codec, Memory, SourceContract}

  for kind <- [:local, :registry] do
    test "#{kind} prepared machines reject pulls before dispatch" do
      {:ok, network} = SmolBox.NetworkPolicy.new(hosts: ["registry.example.com"])
      options = [network: network, pull_sources: [source()]]

      options =
        if unquote(kind) == :registry,
          do:
            Keyword.put(options, :source, %{
              SourceContract.source()
              | credential_ref: nil
            }),
          else: options

      fixture = RuntimeFixture.start(__MODULE__, options)
      handle = running(fixture)

      assert {:error, %{category: :unsupported_capability}} =
               Machines.pull_image(fixture.runtime, handle, "unsupported", source())

      {:ok, pull} = SmolBox.ImagePull.new(source())

      assert {:error, %{category: :unsupported_capability}} =
               Machines.submit(fixture.runtime, handle, %{fixture.spec | command: pull})

      assert pull_count(fixture) == 0
      assert {:ok, %{active_execution: nil}} = Machines.inspect(fixture.runtime, handle)
    end
  end

  for {phase, expected, count} <- [{:before, :completed, 1}, {:after, :unknown, 0}] do
    test "controller loss #{phase} dispatch intent never replays a sent pull" do
      phase = unquote(phase)
      gate = gate(:dispatch_intent, phase)
      fixture = fixture(faults: gate)
      handle = running(fixture)
      {:ok, execution} = Machines.pull_image(fixture.runtime, handle, "pull", source())
      assert_receive {:boundary, :dispatch_intent, ^phase, _blocked}, 5000
      stop_supervised!(Runtime)
      runtime = start_supervised!({Runtime, fixture.options})
      assert {:ok, %{state: unquote(expected)}} = SmolBox.await(runtime, execution, 5000)
      assert pull_count(fixture) == unquote(count)
    end
  end

  test "pull results retain creation identity, capacity and deduplication through restart" do
    fixture = fixture()
    handle = running(fixture)
    assert {:ok, execution} = Machines.pull_image(fixture.runtime, handle, "pull", source())
    assert {:ok, ^execution} = Machines.pull_image(fixture.runtime, handle, "pull", source())

    assert {:ok, %{state: :completed, evidence: :image_pulled, result: image} = record} =
             SmolBox.await(fixture.runtime, execution, 5000)

    assert image.digest_kind == :configuration
    assert image.reference == source().reference
    assert {:ok, <<"smolbox-record-v10\0", payload::binary>> = encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)

    for version <- 1..9 do
      assert {:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload)
    end

    machine = RuntimeFixture.await_idle(fixture.runtime, handle)
    assert machine.spec.artifact == fixture.spec.artifact
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, fixture.options})
    assert {:ok, ^execution} = Machines.pull_image(runtime, handle, "pull", source())
    assert {:ok, %{result: ^image}} = SmolBox.await(runtime, execution, 5000)

    assert {:error, %{category: :identity_conflict}} =
             Machines.pull_image(runtime, handle, "pull", source(), metadata: %{"revision" => 2})

    assert pull_count(fixture) == 1
    assert {:ok, next} = Machines.submit(runtime, handle, fixture.spec)
    assert {:ok, %{state: :completed}} = SmolBox.await(runtime, next, 5000)
  end

  test "two controllers serialize pulls with commands, stop and delete" do
    gate = gate(:pull_image, :after)
    fixture = fixture(faults: gate)
    handle = running(fixture)
    other = second_controller(fixture)
    assert {:ok, first} = Machines.pull_image(fixture.runtime, handle, "pull", source())
    assert_receive {:boundary, :pull_image, :after, blocked}, 5000

    assert {:error, %{category: :admission_exhausted}} =
             Machines.pull_image(other, handle, "competing", source())

    assert {:error, %{category: :admission_exhausted}} =
             Machines.submit(other, handle, fixture.spec)

    {:ok, busy} = Machines.inspect(other, handle)

    for action <- [:stop, :delete] do
      assert {:error, %{category: :admission_exhausted}} =
               apply(Machines, action, [other, handle, busy.version])
    end

    send(blocked, :release_boundary)
    assert {:ok, %{state: :completed}} = SmolBox.await(other, first, 5000)
    assert pull_count(fixture) == 1
  end

  test "lost responses block reuse and are never replayed after restart" do
    fixture = fixture(pull_lost: true)
    handle = running(fixture)
    {:ok, execution} = Machines.pull_image(fixture.runtime, handle, "pull", source())

    assert {:ok, %{state: :unknown, result: nil}} =
             SmolBox.await(fixture.runtime, execution, 5000)

    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, fixture.options})
    assert {:ok, ^execution} = Machines.pull_image(runtime, handle, "pull", source())

    assert {:error, %{category: :admission_exhausted}} =
             Machines.pull_image(runtime, handle, "another", source())

    assert {:ok, %{availability: :empty_or_unavailable}} = Machines.list_images(runtime, handle)
    assert {:ok, %{state: :unknown}} = SmolBox.await(runtime, execution, 5000)
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
    assert pull_count(fixture) == 1
  end

  test "cancelling an in-flight pull does not unlock the machine" do
    gate = gate(:pull_image, :before)
    fixture = fixture(faults: gate)
    handle = running(fixture)

    {:ok, {scope, id} = execution} =
      Machines.pull_image(fixture.runtime, handle, "pull", source())

    assert_receive {:boundary, :pull_image, :before, blocked}, 5000
    assert {:ok, ^execution} = SmolBox.cancel(fixture.runtime, scope, id)
    assert {:ok, %{state: :unknown}} = SmolBox.await(fixture.runtime, execution, 5000)

    assert {:error, %{category: :admission_exhausted}} =
             Machines.submit(fixture.runtime, handle, fixture.spec)

    send(blocked, :release_boundary)
  end

  test "stopped machines reject pulling and passive listing does not start them" do
    fixture = fixture()
    handle = running(fixture)
    idle = RuntimeFixture.await_idle(fixture.runtime, handle)
    {:ok, _} = Machines.stop(fixture.runtime, handle, idle.version)
    assert {:ok, %{state: :stopped}} = Machines.await(fixture.runtime, handle, 5000)

    assert {:error, %{category: :admission_exhausted}} =
             Machines.pull_image(fixture.runtime, handle, "pull", source())

    assert {:ok, %{availability: :empty_or_unavailable}} =
             Machines.list_images(fixture.runtime, handle)

    assert pull_count(fixture) == 0
    assert {:ok, %{state: :stopped}} = Machines.inspect(fixture.runtime, handle)
  end

  test "unapproved pulls, file manifests, offline profiles and disposable pulls are rejected" do
    fixture = fixture()
    handle = running(fixture)

    assert {:error, %{category: :unsupported_capability}} =
             Machines.pull_image(fixture.runtime, handle, "pull", %{source() | id: "unapproved"})

    {:ok, pull} = SmolBox.ImagePull.new(source())
    spec = %{fixture.spec | command: pull}
    assert {:error, _} = SmolBox.ExecutionSpec.validate(%{spec | inputs: [%{}]})
    assert {:error, _} = SmolBox.ExecutionSpec.validate(%{spec | outputs: [%{}]})
    assert {:error, _} = SmolBox.ExecutionSpec.validate(put_in(spec.profile.network, :offline))
    assert {:error, %{category: :unsupported_capability}} = SmolBox.submit(fixture.runtime, spec)
    assert pull_count(fixture) == 0
  end

  test "ownership mismatch prevents both listing and pull dispatch" do
    fixture = fixture()
    handle = running(fixture)
    machine = RuntimeFixture.await_idle(fixture.runtime, handle)

    Agent.update(fixture.peer, fn state ->
      update_in(state.machines[machine.machine_name]["createdAt"], fn _ ->
        1_800_000_000
      end)
    end)

    assert {:error, %{category: :identity_conflict}} =
             Machines.list_images(fixture.runtime, handle)

    {:ok, execution} = Machines.pull_image(fixture.runtime, handle, "pull", source())

    assert {:ok, %{state: :failed, last_error: %{category: :identity_conflict}}} =
             SmolBox.await(fixture.runtime, execution, 5000)

    assert pull_count(fixture) == 0
  end

  defp fixture(options \\ []) do
    {:ok, network} = SmolBox.NetworkPolicy.new(hosts: ["registry.example.com"])

    base = %{
      source()
      | id: "base-image",
        reference: String.replace(source().reference, "/alpine@", "/base@")
    }

    RuntimeFixture.start(
      __MODULE__,
      [network: network, source: base, pull_sources: [source()]] ++ options
    )
  end

  defp source do
    {:ok, source} =
      Source.oci(
        id: "alpine",
        reference: "registry.example.com/team/alpine@sha256:" <> String.duplicate("a", 64),
        architecture: "x86_64"
      )

    source
  end

  defp running(fixture) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: fixture.spec.scope,
        id: "computer",
        artifact: fixture.spec.artifact,
        profile: fixture.spec.profile
      )

    {:ok, handle} = Machines.create(fixture.runtime, spec)
    {:ok, %{state: :created}} = Machines.await(fixture.runtime, handle, 5000)
    idle = RuntimeFixture.await_idle(fixture.runtime, handle)
    {:ok, _} = Machines.start(fixture.runtime, handle, idle.version)
    {:ok, %{state: :running}} = Machines.await(fixture.runtime, handle, 5000)
    handle
  end

  defp gate(event, phase) do
    observer = self()

    start_supervised!(
      {Agent, fn -> %{event: event, phase: phase, observer: observer, fired: false} end},
      id: :gate
    )
  end

  defp second_controller(fixture) do
    options = Keyword.put(fixture.options, :name, SmolBox.ManagedImagesOther)
    start_supervised!({Runtime, options}, id: :second)
  end

  defp pull_count(fixture),
    do:
      Enum.count(ManagedPeer.snapshot(fixture.peer).operations, fn {method, path} ->
        method == "POST" and String.ends_with?(path, "/images/pull")
      end)
end
