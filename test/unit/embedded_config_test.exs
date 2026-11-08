defmodule SmolBox.Embedded.ConfigTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Config, Health, Limits, Protocol}
  alias SmolBox.{Error, Profile, Source}
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

  test "optional approvals fail closed and do not change the helper capability surface" do
    for field <- ~w(sources checkpoints export_destinations checkpoint_policies branch_policies)a,
        invalid <- [nil, [nil], Enum.map(1..33, & &1)] do
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
