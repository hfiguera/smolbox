defmodule SmolBox.Test.EmbeddedPackage do
  @moduledoc false
  alias SmolBox.Embedded.{Config, Limits, Protocol}
  alias SmolBox.Profile

  def create(options \\ []) do
    root = Path.expand(".local/embedded-port-tests-" <> random())
    File.mkdir_p!(root)
    executable = Path.join(root, "smolbox-port")
    python = System.find_executable("python3") || raise "Python 3 required for OS-Port fixture"
    source = File.read!(Path.expand("test/support/embedded_fixture.py"))
    File.write!(executable, "#!" <> python <> "\n" <> source)
    File.chmod!(executable, 0o700)

    identity = %{
      "engine_version" => "0.1.0",
      "smolvm_revision" => "9f446ae00219148ca4a703914f44a8e2fab11655",
      "source_sha256" => String.duplicate("2", 64),
      "build_sha256" => hash(File.read!(executable)),
      "assets_sha256" => String.duplicate("4", 64),
      "platform" => "macos",
      "architecture" => "aarch64"
    }

    minor = Keyword.get(options, :protocol_minor, 3)

    manifest = Jason.encode!(Map.put(manifest_metadata(minor), "identity", identity))
    File.write!(Path.join(root, "package.json"), manifest)

    File.write!(
      Path.join(root, "fixture.json"),
      Jason.encode!(%{
        "identity" => identity,
        "limits" => Protocol.limits(minor),
        "protocol_minor" => minor,
        "capabilities" => Protocol.capabilities(),
        "wrong_hello" => options[:wrong_hello] || false,
        "backend" => options[:backend] || false,
        "persistent_backend" => options[:persistent_backend] || false,
        "ignore_shutdown" => options[:ignore_shutdown] || false,
        "reject_qualification" => options[:reject_qualification] || false,
        "vm_artifact" => options[:vm_artifact] || false
      })
    )

    {:ok, profile} = Profile.new("offline-v1")

    {:ok, limits} =
      Limits.new(
        Keyword.merge(
          [
            handshake_ms: 2000,
            shutdown_ms: 1000,
            cancel_grace_ms: cancel_grace(minor)
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
        platform: :macos,
        architecture: "aarch64",
        artifacts: [
          %{
            "id" => "image",
            "sha256" => String.duplicate("6", 64),
            "architecture" => "aarch64",
            "path" => root <> "/image.smolmachine",
            "max_bytes" => 1_048_576
          }
        ],
        profiles: [profile],
        capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2},
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256},
        limits: limits
      )

    config
  end

  def received(config) do
    case File.read(Path.join(config.package_path, "received.jsonl")) do
      {:ok, text} -> String.split(text, "\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  def receipt(config),
    do: %{
      "target_id" => config.id,
      "domain_generation" => config.domain_generation,
      "name" => "fixture-vm",
      "owner_token" => String.duplicate("7", 64),
      "incarnation" => String.duplicate("8", 32),
      "material_sha256" => String.duplicate("9", 64)
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
  defp manifest_metadata(4), do: %{"schema" => 2, "policy" => %{"port_protocol_minor" => 4}}
  defp manifest_metadata(3), do: %{"schema" => 1}
  defp cancel_grace(4), do: 4000
  defp cancel_grace(3), do: 500
  defp random, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
