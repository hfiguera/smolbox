Code.require_file(Path.expand("../../embedded_port/lib/volume_control.ex", __DIR__))
Code.require_file(Path.expand("../../embedded_port/lib/volume_demo.ex", __DIR__))

defmodule SmolBox.DurableVolumeProof do
  @moduledoc false
  alias SmolBox.DurableHost.{EmbeddedProofConfig, Repo, Store}
  alias SmolBox.Example.EmbeddedVolumes
  alias SmolBox.Example.Setup

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

    target =
      settings
      |> EmbeddedProofConfig.target!()
      |> EmbeddedVolumes.configure(settings["volume_root"])

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
