alias SmolBox.Embedded.Config
alias SmolBox.Profile

package = System.fetch_env!("SMOLBOX_EMBEDDED_PACKAGE") |> Path.expand()
expected_manifest = System.fetch_env!("SMOLBOX_EMBEDDED_MANIFEST_SHA256")
manifest_bytes = File.read!(Path.join(package, "package.json"))
^expected_manifest = Base.encode16(:crypto.hash(:sha256, manifest_bytes), case: :lower)
manifest = Jason.decode!(manifest_bytes)
identity = manifest["identity"]
domain = System.fetch_env!("SMOLBOX_EMBEDDED_DOMAIN_JSON") |> File.read!() |> Jason.decode!()
fixture = System.fetch_env!("SMOLBOX_EMBEDDED_ARTIFACT") |> Path.expand()
fixture_sha = System.fetch_env!("SMOLBOX_EMBEDDED_ARTIFACT_SHA256")

initialize =
  case System.get_env("SMOLBOX_EMBEDDED_INITIALIZE", "false") do
    "true" -> true
    "false" -> false
    _invalid -> raise "SMOLBOX_EMBEDDED_INITIALIZE must be true or false"
  end

{:ok, profile} =
  Profile.new("offline-small",
    cpus: 1,
    memory_mb: 512,
    max_file_bytes: 2_097_152,
    preparation_ms: 120_000,
    execution_ms: 30_000
  )

{:ok, target} =
  Config.new(
    id: domain["target_id"],
    bridge: :port,
    package_path: package,
    package_manifest_sha256: expected_manifest,
    package_identity: identity,
    sdk_identity: get_in(manifest, ["policy", "sdk"]),
    domain_generation: domain["generation"],
    allow_initialize: initialize,
    platform: %{"linux" => :linux, "macos" => :macos}[identity["platform"]],
    architecture: identity["architecture"],
    profiles: [profile],
    artifacts: [
      %{
        "id" => "application",
        "path" => fixture,
        "sha256" => fixture_sha,
        "architecture" => identity["architecture"],
        "max_bytes" => File.stat!(fixture).size
      }
    ],
    capacity: %{slots: 1, cpus: 1, memory_mb: 768, disk_gb: 2},
    allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256}
  )

IO.inspect(target)
