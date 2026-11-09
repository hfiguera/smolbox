Code.require_file(Path.expand("../../embedded_port/lib/volume_control.ex", __DIR__))
Code.require_file(Path.expand("../../embedded_port/lib/volume_demo.ex", __DIR__))

defmodule SmolBox.DurableVolumeProof do
  @moduledoc false
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Embedded.Config
  alias SmolBox.Example.EmbeddedVolumes
  alias SmolBox.Example.Setup
  alias SmolBox.{Files, Profile}

  def run(arguments) do
    {options, [], []} =
      OptionParser.parse(arguments,
        strict: [
          ordinary: :boolean,
          without_rust: :boolean,
          settings: :string,
          phase: :string,
          output: :string,
          expected_records: :string
        ]
      )

    true = options[:ordinary] == true and options[:without_rust] == true
    true = :os.type() == {:unix, :linux}
    nil = System.find_executable("cargo")
    nil = System.find_executable("rustc")
    phase = %{"prepare" => :prepare, "resume" => :resume}[options[:phase]]
    true = phase in [:prepare, :resume]
    settings = options |> Keyword.fetch!(:settings) |> File.read!() |> Jason.decode!()
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

    target = EmbeddedVolumes.configure(target, settings["volume_root"])

    {:ok, store} =
      Store.new(Repo, settings["partition"], Setup.key(settings["encryption_key_file"]))

    expected = Keyword.get(options, :expected_records)

    {:ok, evidence} =
      EmbeddedVolumes.run(target, Keyword.fetch!(options, :output),
        phase: phase,
        scope: settings["scope"],
        mode: :durable,
        store: {Store, store},
        fingerprint_key: Setup.key(settings["fingerprint_key_file"]),
        artifact_root: settings["artifact_root"],
        expected_records: expected
      )

    IO.puts(
      Jason.encode!(
        Map.take(evidence, [
          :phase,
          :prepared_stopped,
          :owned_deleted,
          :separate_normal_beam_restart,
          :historical_output_after_normal_beam_restart,
          :final_reserved_slots,
          :final_reserved_disk_gb,
          :store_mode
        ])
      )
    )
  end
end

SmolBox.DurableVolumeProof.run(System.argv())
