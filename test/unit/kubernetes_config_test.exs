defmodule SmolBox.KubernetesConfigTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Error, Source}
  alias SmolBox.Backend.{Features, Reference}
  alias SmolBox.Kubernetes.{Binding, Config, Shape}
  alias SmolBox.Runtime.{KubernetesSupport, Target}
  alias SmolBox.Test.Kubernetes, as: Fixture

  test "construction and target normalization are offline and redact connection context" do
    assert {:ok, config} = Fixture.config()
    assert :ok == Config.validate(config)
    target = Target.normalize(config)
    assert target.kind == :kubernetes
    assert target.client == nil and target.native_config == nil
    assert target.domain_binding == Config.binding(config)
    assert :ok == Target.validate(target)
    assert Target.id(config) == target.id
    assert Target.endpoint(config) == Target.endpoint(target)
    assert Reference.valid?(Target.connection(target))
    assert Target.sdk_version(config) == nil and Target.sdk_version(target) == nil

    for value <- [config, target, Target.connection(target), Config.binding(config)] do
      refute inspect(value) =~ "private-credential-context"
      refute inspect(value) =~ "private-node-context"
      refute inspect(value) =~ "/private/lab"
    end
  end

  test "enrollment requires exact identities and HTTPS with explicit CA and auth" do
    for options <- [
          [namespace_uid: nil],
          [cluster_anchor_uid: ""],
          [node_boot_id: "unknown"],
          [runtime_class_uid: nil],
          [runtime_policy_digest: "bad"],
          [api_server: "http://127.0.0.1:6443"],
          [api_server: "https://user:secret@server.example"],
          [api_server: "https://server.example/api"],
          [api_server: "https://server.example?token=secret"],
          [api_server: "https://server.example#secret"],
          [api_server: "https://server.example:0"],
          [ca_file: "relative/ca.crt"],
          [ca_file: "/private/../ca.crt"],
          [credential_provider: nil],
          [credential_provider: {__MODULE__, :unknown}],
          [node_evidence: nil],
          [namespace: "Uppercase"],
          [runtime_class: "class/escape"],
          [runtime_identity: Map.put(Fixture.identity(), "extra", "unsupported")]
        ] do
      assert {:error, %Error{category: :validation}} = Fixture.config(options), inspect(options)
    end

    assert {:ok, _} =
             Fixture.config(credential_provider: {:token_file, "/private/projected/token"})

    assert {:error, _} = Fixture.config(credential_provider: {:token_file, "relative/token"})
  end

  test "the preview refuses unqualified platforms, shapes, catalogs and broad capacity" do
    {:ok, config} = Fixture.config()
    profile = hd(config.profiles)
    source = hd(config.sources)

    {:ok, registry} =
      Source.registry(
        id: "pack",
        reference: source.reference,
        content_sha256: Fixture.digest(),
        architecture: "x86_64"
      )

    for options <- [
          [architecture: "aarch64"],
          [platform: :macos],
          [runtime_version: "future"],
          [qualification: :production],
          [profiles: []],
          [sources: []],
          [sources: [source, source]],
          [sources: [registry]],
          [sources: [%{source | architecture: "aarch64"}]],
          [profiles: [profile, profile]],
          [profiles: [%{profile | cpus: 1}]],
          [profiles: [%{profile | storage_gb: 1}]],
          [profiles: [%{profile | host_overhead_mb: 256}]],
          [profiles: [%{profile | max_file_bytes: 2_097_152}]],
          [capacity: %{config.capacity | slots: 2}],
          [allocation_floor: %{config.allocation_floor | overlay_gb: 1}],
          [budget: %{config.budget | max_response_bytes: 3_000_000}]
        ] do
      assert {:error, %Error{category: :validation}} = Fixture.config(options), inspect(options)
    end
  end

  test "binding excludes credentials but changes for every enrolled domain incarnation" do
    {:ok, config} = Fixture.config()
    original = Config.binding(config)
    assert Binding.valid?(original)
    refute SmolBox.Backend.Binding.valid?(original)

    refute Binding.valid?(%SmolBox.Backend.Binding{
             kind: :embedded,
             target_id: "local",
             generation: String.duplicate("a", 32)
           })

    {:ok, rotated} =
      Fixture.config(
        credential_provider: {:token_file, "/different/token"},
        api_server: "https://127.0.0.1:26443"
      )

    assert Config.binding(rotated) == original

    for {key, value} <- [
          namespace_uid: "replacement-ns",
          node_uid: "replacement-node",
          node_boot_id: "00000000-0000-0000-0000-000000000002",
          runtime_class_uid: "replacement-class",
          cluster_anchor_uid: "another-cluster",
          runtime_policy_digest: String.duplicate("b", 64)
        ] do
      {:ok, changed} = Fixture.config([{key, value}])
      refute Config.binding(changed).generation == original.generation
    end

    refute Binding.valid?(%{original | namespace_uid: "replacement-ns"})
    refute Binding.valid?(Map.put(original, :extra, true))
  end

  test "a SmolVM version cannot confer HTTP features or enable dispatch" do
    {:ok, config} = Fixture.config()
    target = Target.normalize(config)
    reference = Target.connection(target)

    for subject <- [config, target, %{kind: :kubernetes, runtime_version: "1.34.0"}],
        feature <-
          ~w(lifecycle foreground_exec files networking extended_exec terminals volumes ports remote_sources branches)a do
      refute Features.supports?(subject, feature)
    end

    for {operation, arity} <- Backend.operations() do
      assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
               Backend.invoke(reference, operation, List.duplicate(nil, arity - 1))
    end

    refute Target.supports?(target, Fixture.execution(config).spec)
    assert {:error, %Error{evidence: :not_dispatched}} = Target.qualify(target, %{})

    assert {:error, %Error{evidence: :not_dispatched}} =
             Target.allocation(target, %{}, "kube-pod")

    assert {:error, %Error{evidence: :not_dispatched}} =
             Target.machine_spec(target, %{}, "kube-pod")

    assert {:error, %Error{category: :unsupported_capability}} =
             KubernetesSupport.verify(%{workers: [target]})

    assert :ok == KubernetesSupport.verify(%{workers: []})
    assert {:error, _} = Target.validate(%{target | id: "another-target"})
  end

  test "canonical intent hashes distinguish container types and ignore map insertion order" do
    assert Shape.digest(%{"a" => 1, "b" => [2, 3]}) ==
             Shape.digest(Map.new([{"b", [2, 3]}, {"a", 1}]))

    refute Shape.digest(%{"a" => 1}) == Shape.digest([{"a", 1}])
    refute Shape.digest([1, 2]) == Shape.digest([2, 1])
    refute Shape.dns_label?(String.duplicate("a", 64))
    assert Shape.dns_label?(String.duplicate("a", 63))
  end

  test "the public runtime constructor cannot enroll a preview before the store gate exists" do
    {:ok, config} = Fixture.config()
    store = start_supervised!(SmolBox.Store.Memory)

    assert {:error, %Error{category: :unsupported_capability, operation: :runtime}} =
             SmolBox.Runtime.Config.new(
               name: SmolBox.KubernetesDisabledRuntime,
               namespace: "kube",
               store: {SmolBox.Store.Memory, store},
               mode: :ephemeral,
               artifact_store: {SmolBox.TestArtifacts, nil},
               fingerprint_key: String.duplicate("k", 32),
               workers: [config]
             )
  end
end
