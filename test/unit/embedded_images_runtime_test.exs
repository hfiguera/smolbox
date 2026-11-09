Code.require_file("examples/embedded_port/lib/images_control.ex")
Code.require_file("examples/embedded_port/lib/images_demo.ex")
Code.require_file("examples/embedded_port/lib/growth_demo.ex")

defmodule SmolBox.EmbeddedImagesRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{
    Image,
    Machines,
    ManagedMachineSpec,
    NetworkPolicy,
    Profile,
    Source,
    TestArtifacts
  }

  alias SmolBox.Example.EmbeddedImages, as: Workflow
  alias SmolBox.Runtime.Session
  alias SmolBox.Store.{Codec, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  test "native registry creation persists cold/warm preparation and releases owned capacity" do
    f = fixture(kind: :registry)
    {:ok, cold} = Machines.inspect(f.runtime, f.key)
    assert %{already_cached: false, size_bytes: 123} = cold.preparation
    assert {:ok, bytes} = Codec.encode(cold)
    assert {:ok, ^cold} = Codec.decode(bytes)
    assert cold.backend_assignment.creation["source"] == Source.artifact(f.source)
    assert Enum.count(requests(f.native), &(&1["operation"] == "prepare_artifact")) == 1
    assert Enum.count(requests(f.native), &(&1["operation"] == "create_registry_prepared")) == 1

    {:ok, _} = Machines.stop(f.runtime, f.key, cold.version)
    {:ok, stopped} = Machines.await(f.runtime, f.key, 5000)
    {:ok, _} = Machines.delete(f.runtime, f.key, stopped.version)
    assert {:ok, %{state: :deleted}} = Machines.await(f.runtime, f.key, 5000)

    spec = %{cold.spec | id: "warm"}
    assert {:ok, warm} = Machines.create(f.runtime, spec)

    assert {:ok, %{state: :stopped, preparation: %{already_cached: true}} = cached} =
             Machines.await(f.runtime, warm, 5000)

    assert {:ok, _} = Machines.delete(f.runtime, warm, cached.version)
    assert {:ok, %{state: :deleted}} = Machines.await(f.runtime, warm, 5000)
    assert {:ok, %{slots: 0}} = Memory.usage(f.store, f.native.id)
    assert Enum.count(requests(f.native), &(&1["operation"] == "prepare_artifact")) == 2
    assert Enum.count(requests(f.native), &(&1["operation"] == "create_registry_prepared")) == 2
  end

  test "failed registry preparation persists its inspection error and resolves only verified absence" do
    f = fixture(kind: :registry, prepare_error: true)
    {:ok, failed} = Machines.inspect(f.runtime, f.key)
    # Bring the next ordinary observation due in this synthetic store; no live
    # SDK state or VM exists and the failed preparation is never replayed.
    assert {:ok, _} =
             Memory.machine(f.store, :write, [
               f.key,
               Session.guard(failed),
               [next_due_at_ms: 0],
               System.system_time(:millisecond)
             ])

    wait(fn ->
      case Machines.inspect(f.runtime, f.key) do
        {:ok, %{state: :unknown, last_error: %{operation: :inspect}, next_due_at_ms: due}} ->
          due > System.system_time(:millisecond)

        _ ->
          false
      end
    end)

    {:ok, blocked} = Machines.inspect(f.runtime, f.key)
    assert blocked.created_machine == nil and blocked.preparation == nil
    assert blocked.operation == :create and blocked.phase == :uncertain
    assert blocked.last_error.evidence == :not_dispatched
    assert blocked.next_due_at_ms > System.system_time(:millisecond)
    assert {:ok, bytes} = Codec.encode(blocked)
    assert {:ok, ^blocked} = Codec.decode(bytes)
    assert {:ok, %{slots: 1}} = Memory.usage(f.store, f.native.id)

    assert {:ok, _} = resolve_owned(f.runtime, f.key, quiesced: true, disposition: :deleted)
    assert {:ok, %{state: :deleted, created_machine: nil}} = Machines.inspect(f.runtime, f.key)
    assert {:ok, %{slots: 0}} = Memory.usage(f.store, f.native.id)
    assert Enum.count(requests(f.native), &(&1["operation"] == "prepare_artifact")) == 1
    refute Enum.any?(requests(f.native), &(&1["operation"] == "create_registry_prepared"))
    refute Enum.any?(requests(f.native), &(&1["operation"] == "inspect"))
  end

  test "an identical native pull reuses its record without competing creation qualification" do
    %{runtime: runtime, key: key, native: native, pull: pull} = fixture()
    assert {:ok, execution} = Machines.pull_image(runtime, key, "pull", pull)

    assert {:ok, %{state: :completed, evidence: :image_pulled, result: image}} =
             SmolBox.await(runtime, execution, 5000)

    assert Image.matches?(image, pull)

    before_retry = requests(native)
    assert Enum.count(before_retry, &(&1["operation"] == "pull_image")) == 1
    # This semantic peer rejects every new creation qualifier after pulling.
    # A retry must return durable identity even when that unrelated work is full.
    assert {:ok, ^execution} = Machines.pull_image(runtime, key, "pull", pull)

    assert {:error, %{category: :identity_conflict, operation: :store, evidence: :not_dispatched}} =
             Machines.pull_image(runtime, key, "pull", pull, metadata: %{"changed" => true})

    after_retry = requests(native)

    qualifiers = fn requests ->
      Enum.count(requests, &(&1["operation"] == "qualify_oci_creation"))
    end

    assert qualifiers.(after_retry) == qualifiers.(before_retry)
    assert Enum.count(after_retry, &(&1["operation"] == "pull_image")) == 1
  end

  test "explicit owned stop collects an unknown pull without closing its original Runtime" do
    f = fixture(name: Workflow, scope: "public-images-proof", pull_error: true)
    assert {:ok, execution} = Machines.pull_image(f.runtime, f.key, "pull", f.pull)
    assert {:ok, %{state: :unknown}} = SmolBox.await(f.runtime, execution, 5000)

    wait(fn ->
      match?(
        {:ok, %{cleanup: :failed}},
        SmolBox.fetch(f.runtime, elem(execution, 0), elem(execution, 1))
      )
    end)

    {:ok, blocked} = Machines.inspect(f.runtime, f.key)
    assert blocked.state == :unknown and blocked.active_execution == execution
    c = %{target: f.native}
    before = requests(f.native)

    assert {:error, %{category: :stale_version}} =
             Workflow.stop_owned(c, "original", blocked.version - 1)

    assert Enum.count(requests(f.native), &(&1["operation"] == "stop")) ==
             Enum.count(before, &(&1["operation"] == "stop"))

    {:ok, health} = SmolBox.Embedded.Port.health({:global, {SmolBox.Embedded.Port, node()}})
    assert {:ok, %{state: :stopped}} = stop_owned(c, f.runtime, f.key)
    {:ok, after_stop} = SmolBox.Embedded.Port.health({:global, {SmolBox.Embedded.Port, node()}})
    assert after_stop.epoch == health.epoch
    assert Process.alive?(f.runtime)

    assert {:ok, %{state: :unknown, active_execution: ^execution} = _unresolved} =
             Machines.inspect(f.runtime, f.key)

    assert {:ok, _} = resolve_owned(f.runtime, f.key)

    assert {:ok, %{state: :stopped, active_execution: nil}} =
             Machines.inspect(f.runtime, f.key)

    assert {:ok, %{state: :unknown, result: nil, cleanup: :complete}} =
             SmolBox.fetch(f.runtime, elem(execution, 0), elem(execution, 1))

    wait(fn -> match?({:ok, [%{status: :ready}]}, SmolBox.workers(f.runtime)) end)
    {:ok, stopped} = Machines.inspect(f.runtime, f.key)
    assert {:ok, _} = Machines.delete(f.runtime, f.key, stopped.version)
    assert {:ok, %{state: :deleted}} = Machines.await(f.runtime, f.key, 5000)
  end

  defp resolve_owned(runtime, key, options \\ [quiesced: true], attempts \\ 100) do
    {:ok, record} = Machines.inspect(runtime, key)

    case Machines.resolve(runtime, key, record.version, options) do
      {:error, %{category: category, evidence: :not_dispatched}}
      when category in [:stale_version, :admission_exhausted] and attempts > 0 ->
        Process.sleep(10)
        resolve_owned(runtime, key, options, attempts - 1)

      result ->
        result
    end
  end

  defp stop_owned(c, runtime, key), do: stop_owned_for(Workflow, c, runtime, key)

  defp stop_owned_for(workflow, c, runtime, key, attempts \\ 100) do
    {:ok, record} = Machines.inspect(runtime, key)

    case workflow.stop_owned(c, "original", record.version) do
      {:error, %{category: category, evidence: :not_dispatched}}
      when category in [:stale_version, :admission_exhausted] and attempts > 0 ->
        Process.sleep(10)
        stop_owned_for(workflow, c, runtime, key, attempts - 1)

      result ->
        result
    end
  end

  test "growth control stops only its original scoped owner and retains unresolved accounting" do
    workflow = SmolBox.Example.EmbeddedGrowth
    f = fixture(name: workflow, scope: "custom-growth-proof", pull_error: true)
    assert {:ok, execution} = Machines.pull_image(f.runtime, f.key, "pull", f.pull)
    assert {:ok, %{state: :unknown}} = SmolBox.await(f.runtime, execution, 5000)

    wait(fn ->
      match?(
        {:ok, %{cleanup: :failed}},
        SmolBox.fetch(f.runtime, elem(execution, 0), elem(execution, 1))
      )
    end)

    {:ok, blocked} = Machines.inspect(f.runtime, f.key)
    before = requests(f.native)
    c = %{target: f.native, scope: "foreign-growth-proof"}
    assert {:error, %{category: :not_found}} = workflow.stop_owned(c, "original", blocked.version)
    c = %{c | scope: elem(f.key, 0)}

    assert {:error, %{category: :stale_version}} =
             workflow.stop_owned(c, "original", blocked.version - 1)

    assert Enum.count(requests(f.native), &(&1["operation"] == "stop")) ==
             Enum.count(before, &(&1["operation"] == "stop"))

    assert {:ok, %{state: :stopped}} = stop_owned_for(workflow, c, f.runtime, f.key)
    assert Process.alive?(f.runtime)

    assert {:ok, %{state: :unknown, active_execution: ^execution, reservation: reservation}} =
             Machines.inspect(f.runtime, f.key)

    assert reservation.slots == 1

    assert {:ok, %{state: :unknown, cleanup: :failed, result: nil}} =
             SmolBox.fetch(f.runtime, elem(execution, 0), elem(execution, 1))

    assert {:ok, _} = resolve_owned(f.runtime, f.key)
    assert {:ok, %{state: :stopped, active_execution: nil}} = Machines.inspect(f.runtime, f.key)
    wait(fn -> match?({:ok, [%{status: :ready}]}, SmolBox.workers(f.runtime)) end)
    {:ok, stopped} = Machines.inspect(f.runtime, f.key)
    assert {:ok, _} = Machines.delete(f.runtime, f.key, stopped.version)
    assert {:ok, %{state: :deleted}} = Machines.await(f.runtime, f.key, 5000)
    assert {:ok, %{slots: 0}} = Memory.usage(f.store, f.native.id)
  end

  test "an unconfirmed owned stop stays uncertain and preserves the command slot" do
    f =
      fixture(
        name: Workflow,
        scope: "public-images-proof",
        pull_error: true,
        stop_no_change: true
      )

    assert {:ok, execution} = Machines.pull_image(f.runtime, f.key, "pull", f.pull)
    assert {:ok, %{state: :unknown}} = SmolBox.await(f.runtime, execution, 5000)

    wait(fn ->
      match?(
        {:ok, %{cleanup: :failed}},
        SmolBox.fetch(f.runtime, elem(execution, 0), elem(execution, 1))
      )
    end)

    assert {:error,
            %{category: :identity_conflict, operation: :stop, evidence: :dispatch_uncertain}} =
             stop_owned(%{target: f.native}, f.runtime, f.key)

    assert {:ok, %{state: :unknown, active_execution: ^execution, reservation: reservation}} =
             Machines.inspect(f.runtime, f.key)

    assert reservation.slots == 1

    assert {:ok, %{state: :unknown, cleanup: :failed, result: nil}} =
             SmolBox.fetch(f.runtime, elem(execution, 0), elem(execution, 1))
  end

  defp fixture(options \\ []) do
    sdk =
      "native/smolbox-protocol/fixtures/hello-v2-linux-images.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["hello", "sdk"])

    native =
      Package.create(
        protocol_major: 2,
        platform: :linux,
        sdk_identity: sdk,
        backend: true,
        persistent_backend: true,
        pull_error: Keyword.get(options, :pull_error, false),
        prepare_error: Keyword.get(options, :prepare_error, false),
        stop_no_change: Keyword.get(options, :stop_no_change, false)
      )

    on_exit(fn -> File.rm_rf!(native.package_path) end)

    source_options = [
      id: "original",
      architecture: "x86_64",
      reference: "registry.example/team/app@sha256:" <> String.duplicate("a", 64)
    ]

    {:ok, source} =
      if options[:kind] == :registry,
        do: Source.registry(source_options ++ [content_sha256: String.duplicate("c", 64)]),
        else: Source.oci(source_options)

    {:ok, pull} =
      Source.oci(
        id: "pull",
        architecture: "x86_64",
        reference: "registry.example/team/other@sha256:" <> String.duplicate("b", 64)
      )

    {:ok, network} = NetworkPolicy.new(hosts: ["registry.example"])

    {:ok, profile} =
      Profile.new("images", network: if(options[:kind] == :registry, do: :offline, else: network))

    native = %{
      native
      | artifacts: [],
        sources: [source, pull],
        profiles: [profile],
        registry_policy:
          if(options[:kind] == :registry,
            do: %SmolBox.Embedded.RegistryPolicy{
              max_download_bytes: 1000,
              max_cache_bytes: 2000,
              max_cache_files: 2
            },
            else: nil
          )
    }

    store = start_supervised!(Memory)
    objects = start_supervised!({Agent, fn -> %{} end})

    runtime =
      start_supervised!(
        {SmolBox,
         name: Keyword.get(options, :name, __MODULE__),
         namespace: "images",
         mode: :ephemeral,
         store: {Memory, store},
         artifact_store: {TestArtifacts, objects},
         fingerprint_key: String.duplicate("k", 32),
         workers: [native],
         poll_ms: 20}
      )

    wait(fn -> match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime)) end)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: Keyword.get(options, :scope, "images"),
        id: "original",
        artifact: Source.artifact(source),
        profile: profile
      )

    assert {:ok, key} = Machines.create(runtime, spec)

    if options[:prepare_error] do
      assert {:ok, %{state: :unknown}} = Machines.await(runtime, key, 5000)
    else
      assert {:ok, %{state: :stopped} = machine} = Machines.await(runtime, key, 5000)
      assert {:ok, _} = Machines.start(runtime, key, machine.version)
      assert {:ok, %{state: :running}} = Machines.await(runtime, key, 5000)
    end

    %{runtime: runtime, key: key, native: native, pull: pull, source: source, store: store}
  end

  defp requests(native),
    do:
      for(
        message <- Package.received(native),
        message["type"] == "request",
        do: message["operation"]
      )

  defp wait(function, attempts \\ 100)
  defp wait(_function, 0), do: flunk("native model did not become ready")

  defp wait(function, attempts) do
    unless function.() do
      Process.sleep(10)
      wait(function, attempts - 1)
    end
  end
end
