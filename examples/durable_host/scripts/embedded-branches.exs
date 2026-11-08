{:ok, _modules, %{compile_warnings: [], runtime_warnings: []}} =
  ~w(branch_control.ex branch_demo.ex)
  |> Enum.map(&Path.expand("../../embedded_port/lib/" <> &1, __DIR__))
  |> Kernel.ParallelCompiler.compile(return_diagnostics: true)

defmodule SmolBox.DurableBranchesProof do
  @moduledoc false
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Branches, Files, Machines, ManagedMachine, Profile}
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Embedded.Config
  alias SmolBox.Example.{EmbeddedBranches, Setup}
  alias SmolBox.Store.Codec

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
    true = options[:phase] in ["exercise", "readback"]
    settings = options |> Keyword.fetch!(:settings) |> File.read!() |> Jason.decode!()

    {:ok, store} =
      Store.new(Repo, settings["partition"], Setup.key(settings["encryption_key_file"]))

    {:ok, %{durable: true, native_branches: 1}} = Store.capabilities(store)

    evidence =
      case options[:phase] do
        "exercise" ->
          {:ok, evidence} =
            EmbeddedBranches.run(target(settings), Keyword.fetch!(options, :output),
              scope: settings["scope"],
              mode: :durable,
              store: {Store, store},
              fingerprint_key: Setup.key(settings["fingerprint_key_file"])
            )

          evidence

        "readback" ->
          readback(settings, store, options)
      end

    EmbeddedBranches.save(Keyword.fetch!(options, :output), "durable-evidence", evidence)
    IO.puts(Jason.encode!(evidence))
  end

  defp target(settings) do
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

    EmbeddedBranches.configure(target)
  end

  # This Runtime has no workers: historical reads and saved backing replies
  # cannot dispatch SDK work or adopt an original native owner.
  defp readback(settings, store, options) do
    expected = expected_records(Keyword.fetch!(options, :expected_records))
    output = Keyword.fetch!(options, :output)
    :ok = File.mkdir(output)
    :ok = File.chmod(output, 0o700)
    objects_path = Path.join(output, "objects")
    :ok = File.mkdir(objects_path)
    :ok = File.chmod(objects_path, 0o700)
    {:ok, objects} = Directory.new(objects_path, max_file_bytes: 131_072)

    runtime_options = [
      name: __MODULE__,
      namespace: "portbranch",
      mode: :durable,
      store: {Store, store},
      artifact_store: {Directory, objects},
      fingerprint_key: Setup.key(settings["fingerprint_key_file"]),
      workers: [],
      lease_ms: 1000,
      poll_ms: 50
    ]

    {:ok, supervisor} =
      Supervisor.start_link([{SmolBox, runtime_options}], strategy: :one_for_one)

    try do
      Enum.each(expected, &read_record/1)

      for child <- Enum.filter(expected, &(is_struct(&1, ManagedMachine) and &1.branch != nil)) do
        {:ok, ^child} = Branches.fetch(__MODULE__, ManagedMachine.key(child))

        {:ok, ^child} =
          Branches.release_storage(__MODULE__, ManagedMachine.key(child), backing_removed: true)
      end

      domain = settings["domain_json"] |> File.read!() |> Jason.decode!()
      {:ok, usage} = Store.usage(store, domain["target_id"])
      true = Enum.all?(usage, fn {_resource, value} -> value == 0 end)

      %{
        phase: "readback",
        store_mode: :durable,
        records_equal_after_normal_beam_exit: length(expected),
        saved_backing_acknowledgements_without_worker: 2,
        native_workers: 0,
        final_reserved_slots: 0,
        final_reserved_disk_gb: 0,
        crash_handling_qualified: false
      }
    after
      :ok = Supervisor.stop(supervisor)
    end
  end

  defp expected_records(path) do
    records =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn value ->
        {:ok, bytes} = Base.decode64(value)
        {:ok, record} = Codec.decode(bytes)
        record
      end)

    machines = Enum.filter(records, &is_struct(&1, ManagedMachine))
    true = Enum.sort(Enum.map(machines, & &1.id)) == ~w(first held source)
    true = Enum.all?(machines, &(&1.state == :deleted and &1.reservation == nil))
    children = Enum.filter(machines, &(&1.branch != nil))
    [_, _] = children
    true = Enum.all?(children, &(&1.branch.state == :closed))
    records
  end

  defp read_record(%ManagedMachine{} = record) do
    {:ok, ^record} = Machines.inspect(__MODULE__, ManagedMachine.key(record))
  end

  defp read_record(record) do
    {:ok, ^record} = SmolBox.fetch(__MODULE__, record.scope, record.id)
  end
end

SmolBox.DurableBranchesProof.run(System.argv())
