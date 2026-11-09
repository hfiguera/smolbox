defmodule SmolBox.Embedded.ConfigTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Checkpoint, Error, Profile, Source}
  alias SmolBox.Embedded.{Config, Health, Launch, Limits, Protocol, RegistryPolicy, SDKIdentity}
  alias SmolBox.Runtime.Target

  defp options do
    {:ok, profile} = Profile.new("offline-v1")

    [
      id: "embedded-local",
      package_path: "/nonexistent/approved-native-package",
      package_manifest_sha256: String.duplicate("1", 64),
      package_identity: %{
        "engine_version" => "0.1.0",
        "smolvm_revision" => "9f446ae00219148ca4a703914f44a8e2fab11655",
        "source_sha256" => String.duplicate("2", 64),
        "build_sha256" => String.duplicate("3", 64),
        "assets_sha256" => String.duplicate("4", 64),
        "platform" => "macos",
        "architecture" => "aarch64"
      },
      domain_generation: String.duplicate("5", 32),
      platform: :macos,
      architecture: "aarch64",
      artifacts: [
        %{
          "id" => "approved-image",
          "sha256" => String.duplicate("6", 64),
          "architecture" => "aarch64",
          "path" => "/nonexistent/private-image.smolmachine",
          "max_bytes" => 1_048_576
        }
      ],
      profiles: [profile],
      capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2},
      allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256}
    ]
  end

  test "configuration makes no package or artifact access and binds a stable domain" do
    assert {:ok, config} = Config.new(options())
    assert :ok = Config.validate(config)
    assert config.bridge == :port
    refute config.allow_initialize
    assert Config.executable(config) == "/nonexistent/approved-native-package/smolbox-port"

    assert Config.domain_binding(config) == %{
             kind: :embedded,
             target_id: "embedded-local",
             generation: String.duplicate("5", 32)
           }

    assert {:ok, initializing} = Config.new(Keyword.put(options(), :allow_initialize, true))
    assert Config.domain_binding(initializing) == Config.domain_binding(config)
    refute Map.has_key?(Config.domain_binding(config), :bridge)
    refute Map.has_key?(Config.domain_binding(config), :epoch)
  end

  test "shared source approval survives normalization without enabling unsupported operations" do
    {:ok, source} =
      Source.oci(
        id: "approved-remote-image",
        reference: "registry.example/team/image@sha256:" <> String.duplicate("a", 64),
        architecture: "aarch64"
      )

    assert {:ok, config} = Config.new(Keyword.put(options(), :sources, [source]))
    target = Target.normalize(config)
    assert target.sources == [source]
    assert target.checkpoints == [] and target.branch_policies == []
    assert :ok = Target.validate(target)
    assert config.package_identity["engine_version"] == "0.1.0"
    assert target.runtime_version == "0.1.0"
    assert Config.sdk_version(config) == "1.22.0"
    assert Target.sdk_version(target) == "1.22.0"
    assert Target.supports_feature?(target, :foreground_exec)

    for feature <- ~w(networking ports workloads remote_sources images background_exec terminals
                       checkpoints exports branches disk_growth volumes)a do
      refute Target.supports_feature?(target, feature)
    end

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             Target.require_operation(target, :pull_image)

    refute inspect(config) =~ "registry.example"
    refute inspect(target) =~ "registry.example"
    assert_invalid(Keyword.put(options(), :sources, [source, source]))
    assert_invalid(Keyword.put(options(), :sources, [%{source | architecture: "x86_64"}]))
  end

  test "registry policy is required by an explicitly approved remote source descriptor" do
    {:ok, source} =
      Source.registry(
        id: "registry",
        reference: "registry.example/team/app@sha256:" <> String.duplicate("a", 64),
        architecture: "aarch64",
        content_sha256: String.duplicate("b", 64)
      )

    {:ok, policy} =
      RegistryPolicy.new(max_download_bytes: 1024, max_cache_bytes: 4096, max_cache_files: 2)

    {:ok, dormant} =
      Config.new(Keyword.merge(options(), sources: [source], registry_policy: policy))

    refute Map.has_key?(Launch.helper_config(dormant), "approved_registry_sources")
    package = Map.put(dormant.package_identity, "engine_version", "0.2.0")
    sdk = SDKIdentity.implemented("1.22.0", package["smolvm_revision"])
    sdk = put_in(sdk, ["feature_versions", "remote_sources"], 1)
    approved = %{dormant | package_identity: package, sdk_identity: sdk}
    assert :ok = Config.validate(approved)
    assert :ok = Config.validate(%{approved | artifacts: []})
    assert {:error, _} = Config.validate(%{approved | registry_policy: nil})
    assert [approval] = Launch.helper_config(approved)["approved_registry_sources"]
    assert approval["source"]["content_sha256"] == source.content_sha256
    assert approval["cache_policy"] == %{"max_bytes" => 4096, "max_files" => 2}
    refute Map.has_key?(approval, "identity_token")
  end

  test "optional approvals fail closed and do not change the helper capability surface" do
    for field <- ~w(sources checkpoints export_destinations checkpoint_policies branch_policies)a,
        invalid <- [nil, [nil], Enum.to_list(1..33)] do
      assert_invalid(Keyword.put(options(), field, invalid))
    end

    for {field, invalid} <- [volume_policy: %{}, registry_credentials: :invalid] do
      assert_invalid(Keyword.put(options(), field, invalid))
    end

    {:ok, config} = Config.new(options())
    health = Health.describe(config, %{status: :ready, protocol_minor: 4})
    assert health.sdk_version == "1.22.0"
    assert health.engine_version == "0.1.0"
    assert health.capabilities == Protocol.capabilities()
    assert health.protocol_version == %{major: 1, minor: 4}

    unknown = %{
      config
      | package_identity: %{config.package_identity | "smolvm_revision" => "unknown"}
    }

    assert Config.sdk_version(unknown) == nil
    assert Target.sdk_version(%{runtime_version: "1.19.0"}) == "1.19.0"
  end

  test "checkpoint-only workers require an approved checkpoint-capable package" do
    options = options()
    [profile] = options[:profiles]

    {:ok, checkpoint} =
      Checkpoint.new(
        id: "approved-idle",
        sha256: String.duplicate("a", 64),
        architecture: "aarch64",
        platform: :macos,
        path: "/nonexistent/idle.smolcheckpoint",
        profile: profile
      )

    options = Keyword.merge(options, artifacts: [], checkpoints: [checkpoint])
    assert_invalid(options)

    package = Map.put(options[:package_identity], "engine_version", "0.2.0")
    sdk = SDKIdentity.implemented("1.22.0", package["smolvm_revision"])
    options = Keyword.merge(options, package_identity: package, sdk_identity: sdk)
    assert_invalid(options)

    sdk = put_in(sdk, ["feature_versions", "checkpoints"], 1)
    options = Keyword.put(options, :sdk_identity, sdk)
    assert {:ok, config} = Config.new(options)
    assert :ok = config |> Target.normalize() |> Target.validate()

    assert %{"approved_artifacts" => [], "approved_checkpoints" => [approval]} =
             Launch.helper_config(config)

    assert approval["source"] == Checkpoint.artifact(checkpoint)

    assert_invalid(Keyword.put(options, :checkpoints, []))
    assert_invalid(Keyword.put(options, :checkpoints, [%{checkpoint | architecture: "x86_64"}]))
  end

  test "volume root enters helper config only under an explicitly approved Linux descriptor" do
    {:ok, policy} = SmolBox.VolumePolicy.new("local", "/srv/smolvm/volumes")
    options = options()

    package =
      options[:package_identity]
      |> Map.merge(%{"platform" => "linux", "architecture" => "x86_64"})

    artifacts = Enum.map(options[:artifacts], &Map.put(&1, "architecture", "x86_64"))

    {:ok, dormant} =
      Config.new(
        Keyword.merge(options,
          platform: :linux,
          architecture: "x86_64",
          package_identity: package,
          artifacts: artifacts,
          volume_policy: policy
        )
      )

    refute Map.has_key?(Launch.helper_config(dormant), "approved_volume_policy")
    package = Map.put(dormant.package_identity, "engine_version", "0.2.0")
    sdk = SDKIdentity.implemented("1.22.0", package["smolvm_revision"])
    sdk = put_in(sdk, ["feature_versions", "volumes"], 1)
    future = %{dormant | package_identity: package, sdk_identity: sdk}
    assert :ok = Config.validate(future)

    assert Launch.helper_config(future)["approved_volume_policy"] ==
             %{"id" => "local", "root" => "/srv/smolvm/volumes"}

    refute Map.has_key?(
             Launch.helper_config(%{future | volume_policy: nil}),
             "approved_volume_policy"
           )
  end

  test "identity must match the configured platform and pinned engine" do
    package = options()[:package_identity]

    for {field, value} <- [
          {"engine_version", "future"},
          {"smolvm_revision", String.duplicate("0", 40)},
          {"source_sha256", "invalid"},
          {"build_sha256", String.duplicate("A", 64)},
          {"assets_sha256", nil},
          {"platform", "linux"},
          {"architecture", "x86_64"}
        ] do
      assert_invalid(Keyword.put(options(), :package_identity, Map.put(package, field, value)))
    end

    assert_invalid(Keyword.put(options(), :package_identity, Map.put(package, "extra", true)))
    assert_invalid(Keyword.put(options(), :package_identity, nil))
    assert_invalid(Keyword.put(options(), :platform, :windows))
    assert_invalid(Keyword.put(options(), :domain_generation, String.duplicate("f", 31)))
    assert_invalid(Keyword.put(options(), :id, "http:local"))
    assert_invalid(Keyword.put(options(), :id, "."))
    assert_invalid(Keyword.put(options(), :id, ".."))
    assert_invalid(Keyword.put(options(), :id, ".hidden"))
  end

  test "Linux ARM64 uses the Linux descriptor and keeps checkpoint host identity distinct" do
    options = options()

    package =
      Map.merge(options[:package_identity], %{"platform" => "linux", "engine_version" => "0.2.0"})

    sdk = SDKIdentity.implemented("1.22.0", package["smolvm_revision"])
    sdk = put_in(sdk, ["feature_versions", "checkpoints"], 1)
    [profile] = options[:profiles]

    assert {:ok, checkpoint} =
             Checkpoint.new(
               id: "arm-idle",
               sha256: String.duplicate("a", 64),
               architecture: "aarch64",
               platform: :linux,
               path: "/approved/arm-idle.smolcheckpoint",
               profile: profile
             )

    options =
      Keyword.merge(options,
        platform: :linux,
        package_identity: package,
        sdk_identity: sdk,
        checkpoints: [checkpoint]
      )

    assert {:ok, config} = Config.new(options)
    assert :ok = config |> Target.normalize() |> Target.validate()

    assert %{"approved_checkpoints" => [%{"host_platform" => "linux/arm64"}]} =
             Launch.helper_config(config)

    assert_invalid(Keyword.put(options, :checkpoints, [%{checkpoint | platform: :macos}]))

    assert_invalid(
      Keyword.put(options, :package_identity, %{package | "architecture" => "x86_64"})
    )
  end

  test "reject unsupported bridge and arbitrary domain paths before startup" do
    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             Config.new(Keyword.put(options(), :bridge, :rustler))

    for option <- [db_path: "/tmp/db", vm_root: "/tmp/vms", detached: true, bridge: :kubernetes] do
      assert_invalid(options() ++ [option])
    end

    assert_invalid(options() ++ [id: "duplicate"])
    assert_invalid(Keyword.delete(options(), :domain_generation))
    assert_invalid(Keyword.put(options(), :package_path, "/approved/../other"))
    assert_invalid(Keyword.put(options(), :package_path, "/"))
  end

  test "reject artifact catalog ambiguity, extra approvals, and unbounded verification" do
    [artifact] = options()[:artifacts]

    for artifacts <- [
          [],
          [nil],
          [artifact, artifact],
          [artifact, Map.put(artifact, "id", "second-id")],
          [Map.put(artifact, "kind", "oci")],
          [Map.put(artifact, "max_bytes", 34_359_738_369)],
          [Map.put(artifact, "max_bytes", 0)],
          [Map.put(artifact, "architecture", "x86_64")],
          [Map.put(artifact, "path", "relative.smolmachine")],
          [Map.put(artifact, "path", "/path/../other.smolmachine")]
        ] do
      assert_invalid(Keyword.put(options(), :artifacts, artifacts))
    end
  end

  test "approved profiles cannot enlarge the native capability matrix or ignore disk floors" do
    [profile] = options()[:profiles]

    for profiles <- [
          [],
          [nil],
          [profile, profile],
          [%{profile | cpus: 17}],
          [%{profile | execution_ms: 86_400_001}],
          [%{profile | host_overhead_mb: 128}],
          [%{profile | network: true}]
        ] do
      assert_invalid(Keyword.put(options(), :profiles, profiles))
    end

    {:ok, network} = SmolBox.NetworkPolicy.new(cidrs: ["1.1.1.1/32"])
    assert_invalid(Keyword.put(options(), :profiles, [%{profile | network: network}]))

    assert_invalid(
      Keyword.put(options(), :allocation_floor, %{
        storage_gb: 2,
        overlay_gb: 1,
        host_overhead_mb: 256
      })
    )

    assert_invalid(Keyword.put(options(), :allocation_floor, nil))

    assert_invalid(
      Keyword.put(options(), :capacity, %{slots: 0, cpus: 1, memory_mb: 512, disk_gb: 2})
    )
  end

  test "malformed structs fail closed and configuration inspection redacts private approvals" do
    {:ok, config} = Config.new(options())

    for invalid <- [nil, %{}, Map.put(config, :extra, true), %{config | limits: nil}] do
      assert {:error, %Error{category: :validation, evidence: :not_dispatched}} =
               Config.validate(invalid)
    end

    for private <- ["nonexistent", "private-image", "approved-image", config.domain_generation] do
      refute inspect(config) =~ private
    end

    assert_invalid(Keyword.put(options(), :budget, %{config.budget | timeout_ms: 86_400_001}))

    assert_invalid(
      Keyword.put(options(), :budget, %{config.budget | max_request_bytes: 1_048_577})
    )

    assert_invalid(
      Keyword.put(options(), :budget, %{config.budget | max_response_bytes: 16_777_217})
    )
  end

  test "bridge limits tighten fixed bounds and retain independent finite grace periods" do
    assert {:ok, defaults} = Limits.new()
    assert {:ok, limits} = Limits.new(in_flight: 1, initial_credit_bytes: 65_536)
    assert limits.in_flight == 1
    assert limits.initial_credit_bytes == 65_536
    assert defaults.cancel_grace_ms > 0
    assert defaults.shutdown_ms > 0

    for option <- [in_flight: 33, send_queue_bytes: 4_194_305, initial_credit_bytes: 262_145] do
      assert {:error, %Error{category: :validation}} = Limits.new([option])
    end

    for option <- [handshake_ms: 0, cancel_grace_ms: :infinity, shutdown_ms: nil] do
      assert {:error, %Error{category: :validation}} = Limits.new([option])
    end

    assert {:error, %Error{category: :validation}} = Limits.new(in_flight: 1, in_flight: 2)
    assert {:error, %Error{category: :validation}} = Limits.new(event_queue_bytes: 65_536)
    assert {:error, %Error{category: :validation}} = Limits.new(initial_credit_events: 65)
    assert {:error, %Error{category: :validation}} = Limits.new(event_queue_events: 2047)

    assert {:ok, _limits} =
             Limits.new(in_flight: 1, initial_credit_bytes: 65_536, event_queue_bytes: 65_536)

    assert {:error, %Error{category: :validation}} = Limits.validate(Map.put(defaults, :extra, 1))
  end

  defp assert_invalid(options) do
    assert {:error, %Error{category: :validation, evidence: :not_dispatched}} =
             Config.new(options)
  end
end
