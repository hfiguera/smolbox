defmodule SmolBox.Test.EmbeddedPackage do
  @moduledoc false
  alias SmolBox.Embedded.{Config, Limits, Protocol, SDKIdentity}
  alias SmolBox.Profile

  def create(options \\ []) do
    root = Path.expand(".local/embedded-port-tests-" <> random())
    File.mkdir_p!(root)
    executable = Path.join(root, "smolbox-port")
    python = System.find_executable("python3") || raise "Python 3 required for OS-Port fixture"
    source = File.read!(Path.expand("test/support/embedded_fixture.py"))
    File.write!(executable, "#!" <> python <> "\n" <> source)
    File.chmod!(executable, 0o700)

    major = Keyword.get(options, :protocol_major, 1)
    minor = Keyword.get(options, :protocol_minor, if(major == 2, do: 0, else: 3))
    platform = Keyword.get(options, :platform, :macos)
    architecture = if platform == :linux, do: "x86_64", else: "aarch64"

    identity = %{
      "engine_version" => if(major == 2, do: "0.2.0", else: "0.1.0"),
      "smolvm_revision" => "9f446ae00219148ca4a703914f44a8e2fab11655",
      "source_sha256" => String.duplicate("2", 64),
      "build_sha256" => hash(File.read!(executable)),
      "assets_sha256" => String.duplicate("4", 64),
      "platform" => Atom.to_string(platform),
      "architecture" => architecture
    }

    sdk = options[:sdk_identity] || SDKIdentity.implemented("1.22.0", identity["smolvm_revision"])
    manifest = Jason.encode!(Map.put(manifest_metadata(major, minor, sdk), "identity", identity))
    File.write!(Path.join(root, "package.json"), manifest)

    File.write!(
      Path.join(root, "fixture.json"),
      Jason.encode!(fixture_metadata(identity, major, minor, options))
    )

    {:ok, profile} = Profile.new("offline-v1")

    {:ok, limits} =
      Limits.new(
        Keyword.merge(
          [
            handshake_ms: 2000,
            shutdown_ms: 1000,
            cancel_grace_ms: cancel_grace(major, minor)
          ],
          options[:limits] || []
        )
      )

    {:ok, config} =
      Config.new(
        id: "port-fixture",
        package_path: root,
        package_manifest_sha256: hash(manifest),
        package_identity: identity,
        domain_generation: String.duplicate("5", 32),
        platform: platform,
        architecture: architecture,
        artifacts: [
          %{
            "id" => "image",
            "sha256" => String.duplicate("6", 64),
            "architecture" => architecture,
            "path" => root <> "/image.smolmachine",
            "max_bytes" => 1_048_576
          }
        ],
        profiles: [profile],
        capacity: options[:capacity] || %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2},
        volume_policy: options[:volume_policy],
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256},
        limits: limits,
        sdk_identity: if(major == 2, do: sdk, else: nil)
      )

    config
  end

  def remove!(config), do: remove_tree!(config.package_path, 20)

  defp remove_tree!(root, attempts) do
    case File.rm_rf(root) do
      {:ok, _removed} ->
        :ok

      # The helper may finish an atomic snapshot after its Port closes.
      {:error, reason, _path} when reason in [:eexist, :enotempty] and attempts > 0 ->
        Process.sleep(10)
        remove_tree!(root, attempts - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove embedded test package", path: path
    end
  end

  def received(config), do: read_received(Path.join(config.package_path, "received.jsonl"), 20)

  defp read_received(path, retries) do
    case File.read(path) do
      {:ok, ""} -> []
      {:ok, text} -> decode_received(path, text, retries)
      {:error, :enoent} -> []
    end
  end

  defp decode_received(path, text, retries) do
    cond do
      String.ends_with?(text, "\n") ->
        text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      retries > 0 ->
        # A concurrent append can leave a partial final line in this snapshot.
        Process.sleep(5)
        read_received(path, retries - 1)

      true ->
        raise "incomplete request record in Port fixture log"
    end
  end

  def receipt(config) do
    receipt = %{
      "target_id" => config.id,
      "domain_generation" => config.domain_generation,
      "name" => "fixture-vm",
      "owner_token" => String.duplicate("7", 64),
      "incarnation" => String.duplicate("8", 32),
      "material_sha256" => String.duplicate("9", 64)
    }

    if Config.protocol_major(config) == 2,
      do: Map.put(receipt, "material", material()),
      else: receipt
  end

  defp material,
    do: %{
      "schema" => 2,
      "revision" => 0,
      "record_sha256" => String.duplicate("9", 64),
      "chain_sha256" => String.duplicate("a", 64),
      "operation_id" => nil,
      "request_sha256" => nil
    }

  def command(config, mode),
    do: %{
      "operation" => "exec",
      "receipt" => receipt(config),
      "command" => %{
        "argv" => [mode],
        "env" => %{},
        "workdir" => nil,
        "user" => nil,
        "max_output_bytes" => 16_777_216
      }
    }

  def hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp fixture_metadata(identity, major, minor, options) do
    sdk =
      if(major == 2,
        do:
          options[:sdk_identity] || SDKIdentity.implemented("1.22.0", identity["smolvm_revision"]),
        else: nil
      )

    %{
      "identity" => identity,
      "limits" => Protocol.limits(major, minor, sdk),
      "protocol_major" => major,
      "protocol_minor" => minor,
      "sdk" => sdk,
      "capabilities" => Protocol.capabilities(sdk),
      "wrong_hello" => options[:wrong_hello] || false,
      "backend" => options[:backend] || false,
      "persistent_backend" => options[:persistent_backend] || false,
      "ignore_shutdown" => options[:ignore_shutdown] || false,
      "reject_qualification" => options[:reject_qualification] || false,
      "vm_artifact" => options[:vm_artifact] || false,
      "minimum_material_revision" => Keyword.get(options, :minimum_material_revision, 0),
      "pull_error" => Keyword.get(options, :pull_error, false),
      "prepare_error" => Keyword.get(options, :prepare_error, false),
      "capture_transition" => options[:capture_transition],
      "unreachable_after_start" => Keyword.get(options, :unreachable_after_start, false),
      "stop_no_change" => Keyword.get(options, :stop_no_change, false)
    }
    |> Map.merge(volume_metadata(options))
    |> Map.put(
      "reject_terminal_preflight",
      Keyword.get(options, :reject_terminal_preflight, false)
    )
  end

  defp volume_metadata(options),
    do: %{
      "volume_mode" => options[:volume_mode],
      "volume_delay_ms" => options[:volume_delay_ms] || 0
    }

  defp manifest_metadata(2, 0, sdk) do
    policy = "native/policy.json" |> File.read!() |> Jason.decode!() |> Map.put("sdk", sdk)

    policy =
      if sdk["feature_versions"]["observability"] == 1,
        do: Map.put(policy, "observation_limits", Protocol.limits(2, 0, sdk)["observations"]),
        else: Map.delete(policy, "observation_limits")

    policy =
      if sdk["feature_versions"]["compact_creation"] == 1,
        do: Map.put(policy, "creation_limits", Protocol.limits(2, 0, sdk)["creation"]),
        else: Map.delete(policy, "creation_limits")

    policy =
      if sdk["feature_versions"]["job_resources"] == 1,
        do: Map.put(policy, "job_limits", Protocol.limits(2, 0, sdk)["jobs"]),
        else: Map.delete(policy, "job_limits")

    policy =
      if sdk["feature_versions"]["buffered_exec"] == 1,
        do: Map.put(policy, "buffered_limits", Protocol.limits(2, 0, sdk)["buffered"]),
        else: Map.delete(policy, "buffered_limits")

    policy =
      if sdk["feature_versions"]["logs"] == 1,
        do: Map.put(policy, "log_limits", Protocol.limits(2, 0, sdk)["logs"]),
        else: Map.delete(policy, "log_limits")

    policy =
      if sdk["feature_versions"]["volumes"] == 1,
        do: Map.put(policy, "volume_limits", Protocol.limits(2, 0, sdk)["volumes"]),
        else: Map.delete(policy, "volume_limits")

    %{"schema" => 3, "policy" => policy}
  end

  defp manifest_metadata(1, 4, _sdk),
    do: %{"schema" => 2, "policy" => %{"port_protocol_minor" => 4}}

  defp manifest_metadata(1, 3, _sdk), do: %{"schema" => 1}
  defp cancel_grace(2, 0), do: 4000
  defp cancel_grace(1, 4), do: 4000
  defp cancel_grace(1, 3), do: 500
  defp random, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
