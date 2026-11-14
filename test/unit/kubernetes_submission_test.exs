defmodule SmolBox.KubernetesSubmissionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ExecutionSpec, Source}
  alias SmolBox.Runtime.{Config, KubernetesSupport, Target, WorkerConfig}
  alias SmolBox.Store.Memory
  alias SmolBox.Test.Kubernetes, as: Fixture

  defmodule OldStore do
    @moduledoc false
    def capabilities(_),
      do:
        {:ok,
         %{schema: 1, atomic: true, durable: false, backend_bindings: 1, backend_recovery: 1}}
  end

  test "public submission gates exact OCI approval and preserves first acceptance deadline" do
    {:ok, config} = Fixture.config()
    store = start_supervised!(Memory)
    runtime = start_supervised!({SmolBox, options(config, store)})
    spec = Fixture.execution(config).spec
    assert {:ok, handle} = SmolBox.submit(runtime, spec)
    assert {:ok, first} = SmolBox.fetch(runtime, spec.scope, spec.id)
    assert first.backend_assignment == nil
    assert {:ok, ^handle} = SmolBox.submit(runtime, spec)
    assert {:ok, same} = SmolBox.fetch(runtime, spec.scope, spec.id)
    assert same.deadlines == first.deadlines

    assert {:error, %{category: :identity_conflict}} =
             SmolBox.submit(runtime, %{spec | queue_ms: spec.queue_ms + 1})

    assert {:error, %{category: :unsupported_capability}} =
             SmolBox.submit(runtime, %{spec | retention_ms: 60_000})

    {:ok, foreign} =
      Source.oci(
        id: "other",
        reference: "registry.example/other@sha256:" <> Fixture.digest(),
        architecture: "x86_64"
      )

    assert {:error, %{category: :unsupported_capability}} =
             SmolBox.submit(runtime, %{spec | id: "foreign", artifact: Source.artifact(foreign)})

    assert {:ok, %{slots: 0}} = Memory.usage(store, config.id)

    assert {:error, %{category: :unsupported_capability}} =
             SmolBox.Machines.submit(runtime, {spec.scope, "machine"}, spec)
  end

  test "zero retention cannot expand the existing HTTP or Embedded admission policy" do
    {:ok, config} = Fixture.config()
    spec = Fixture.execution(config).spec
    assert :ok == ExecutionSpec.validate(spec)
    assert {:error, _} = ExecutionSpec.validate(%{spec | retention_ms: 1})

    assert {:error, _} =
             ExecutionSpec.validate(%{spec | command: %{spec.command | stdin: "input"}})

    assert {:error, _} =
             ExecutionSpec.validate(%{spec | command: %{spec.command | background: true}})

    refute Target.supports?(Target.normalize(config), %{spec | retention_ms: 60_000})
    refute WorkerConfig.supports?(%{}, spec)

    assert {:error, _} =
             KubernetesSupport.verify(%{
               workers: [Target.normalize(config)],
               store: {OldStore, nil}
             })

    store = start_supervised!(Memory)
    assert {:ok, runtime_config} = Config.new(options(config, store))
    assert :ok == KubernetesSupport.verify(runtime_config)

    assert {:error, _} =
             KubernetesSupport.verify(%{
               runtime_config
               | workers: runtime_config.workers ++ runtime_config.workers
             })
  end

  defp options(config, store),
    do: [
      name: __MODULE__.Runtime,
      namespace: "kube",
      store: {Memory, store},
      mode: :ephemeral,
      artifact_store: {SmolBox.TestArtifacts, nil},
      fingerprint_key: String.duplicate("k", 32),
      workers: [config]
    ]
end
