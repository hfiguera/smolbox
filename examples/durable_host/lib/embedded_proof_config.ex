defmodule SmolBox.DurableHost.EmbeddedProofConfig do
  @moduledoc false

  alias SmolBox.Embedded.Config
  alias SmolBox.{Files, Profile}

  def target!(settings) do
    manifest_bytes = File.read!(Path.join(settings["package"], "package.json"))
    true = Files.sha256(manifest_bytes) == settings["manifest_sha256"]
    manifest = Jason.decode!(manifest_bytes)
    domain = settings["domain_json"] |> File.read!() |> Jason.decode!()
    {:ok, profile} = Profile.new("placeholder", cpus: 1, memory_mb: 512)

    {:ok, target} =
      Config.new(
        id: domain["target_id"],
        package_path: settings["package"],
        package_manifest_sha256: settings["manifest_sha256"],
        package_identity: manifest["identity"],
        sdk_identity: manifest["policy"]["sdk"],
        domain_generation: domain["generation"],
        platform: :linux,
        architecture: "x86_64",
        profiles: [profile],
        artifacts: [
          %{
            "id" => "application",
            "path" => settings["artifact"],
            "sha256" => settings["artifact_sha256"],
            "architecture" => "x86_64",
            "max_bytes" => File.stat!(settings["artifact"]).size
          }
        ],
        capacity: %{slots: 1, cpus: 1, memory_mb: 768, disk_gb: 10},
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256}
      )

    target
  end
end
