defmodule SmolBox.CI.Package do
  @moduledoc false
  alias SmolBox.CI.{NativeConsumer, Util}

  @root Path.expand("../../..", __DIR__)
  @limit 64 * 1024 * 1024
  @minimum %{
    "req" => "0.7.4",
    "mint" => "1.11.0",
    "mint_web_socket" => "1.0.6",
    "jason" => "1.4.0",
    "telemetry" => "1.3.0",
    "nimble_options" => "1.1.0"
  }
  @forbidden ~w(credo ex_slop ex_dna credence dialyxir ex_doc mix_audit ecto ecto_sql postgrex stream_data plug bandit)
  @public ~w(mix.exs README.md CHANGELOG.md LICENSE docs/notebooks/getting-started.livemd examples/embedded_port/scripts/quickstart.exs)
  @docs ~w(getting-started supported-platforms troubleshooting client embedded-port embedded-quickstart host-integration recovery upgrading upgrading-within-0.1.x upgrading-to-0.2.0 upgrading-to-0.2.1 upgrading-to-0.3.0 upgrading-to-0.3.1 upgrading-to-0.4.0 upgrading-to-0.4.1 upgrading-to-0.4.2 upgrading-to-0.4.3 testing telemetry worker-measurements worker-measurements-validation worker-draining worker-draining-validation disk-expansion local-volumes security resource-qualification provisioning-performance compatibility network-access network-access-validation port-mappings port-mappings-validation long-running-exec long-running-exec-validation workloads workloads-validation guest-files guest-files-validation images-and-registry-artifacts images-and-registry-artifacts-validation machine-exports managed-checkpoints managed-branches interactive-terminals interactive-terminals-validation checkpoints persistent-machines persistent-machines-validation runtime-1.17.0-qualification runtime-1.19.0-qualification runtime-1.20.2-qualification runtime-1.22.0-qualification evidence/smolvm-1.34.0-qualification evidence/embedded-port-1.34.0-release-sources)

  def run(arguments) do
    {options, []} =
      Util.options!(
        arguments,
        [
          minimum: :boolean,
          report: :string,
          package_output: :string,
          archive: :string,
          without_rust: :boolean,
          native_package: :string,
          native_fixture: :string,
          native_sha256: :string,
          native_domain_json: :string,
          native_output: :string,
          native_ordinary: :boolean,
          native_public: :boolean,
          native_branches: :boolean,
          native_checkpoints: :boolean,
          native_checkpoint_seed: :string,
          native_checkpoint_seed_sha256: :string,
          native_terminal: :boolean,
          native_volume: :boolean,
          native_growth: :boolean,
          native_growth_settings: :string,
          native_images: :boolean,
          native_images_settings: :string,
          native_volume_root: :string,
          native_network: :boolean,
          native_workload: :boolean,
          native_host_port: :integer,
          namespace_identity: :string
        ],
        [:report]
      )

    NativeConsumer.validate_options!(options)

    for key <- [:report, :package_output],
        file = options[key],
        do: Util.ensure!(!File.exists?(file), "output already exists")

    root = Util.temporary("smolbox-consumer")

    try do
      archive = Path.join(root, "smolbox.tar")

      if source = options[:archive] do
        Util.ensure!(File.stat!(source).size <= @limit, "archive exceeds size bound")
        File.cp!(source, archive)
      else
        Util.command!(["mix", "hex.build", "--output", archive],
          cd: @root,
          env: [{"MIX_ENV", "dev"}]
        )
      end

      package = Path.join(root, "package")
      names = unpack!(archive, package)
      hashes = hashes(package, names)
      consumer = prepare_consumer(root, options[:minimum])

      environment = consumer_environment(consumer, options)

      for command <- [
            ["mix", "deps.get", "--only", "prod"],
            ["mix", "compile", "--warnings-as-errors"]
          ] do
        Util.command!(command, cd: consumer, env: environment, timeout: 600_000)
      end

      Util.command!(["mix", "compile", "--force", "--no-deps-check", "--warnings-as-errors"],
        cd: package,
        env: environment,
        timeout: 600_000
      )

      Util.command!(["mix", "run", "--no-compile", "smoke.exs"], cd: consumer, env: environment)
      report = report!(consumer, package, archive, names, hashes, options[:minimum] || false)
      report = native_report(report, consumer, environment, options)
      Util.ensure!(hashes == hashes(package, names), "native consumer changed package source")

      if output = options[:package_output] do
        File.mkdir_p!(Path.dirname(output))
        File.write!(output, File.read!(archive), [:exclusive])
      end

      Util.write_json!(options[:report], report)
      IO.puts("Package consumer passed: #{options[:report]}")
    after
      cleanup_source(root)
    end
  end

  @doc false
  def cleanup_source(root) do
    if NativeConsumer.retained_source?(Path.join(root, "consumer")),
      do: :retained,
      else: File.rm_rf!(root)
  end

  defp consumer_environment(consumer, options) do
    [
      {"MIX_ENV", "prod"},
      {"SMOLBOX_CONSUMER_WITHOUT_RUST", if(options[:without_rust], do: "1", else: nil)},
      {"MIX_DEPS_PATH", Path.join(consumer, "deps")},
      {"MIX_BUILD_PATH", Path.join(consumer, "_build/prod")}
    ]
  end

  defp native_report(report, consumer, environment, options) do
    native = NativeConsumer.run(consumer, environment, options)

    if options[:without_rust],
      do: Util.ensure!(report.smoke["without_rust"] == true, "consumer did not verify no Rust")

    Map.merge(report, %{without_rust: Keyword.get(options, :without_rust, false), native: native})
  end

  def unpack!(archive, destination) do
    Util.ensure!(File.stat!(archive).size <= @limit, "package exceeds qualification size limit")
    outer = File.read!(archive)
    entries = table!(outer)

    Util.ensure!(
      Enum.sort(Enum.map(entries, &elem(&1, 0))) ==
        Enum.sort(~w(VERSION CHECKSUM metadata.config contents.tar.gz)),
      "unexpected Hex archive members"
    )

    {:ok, files} = :erl_tar.extract({:binary, outer}, [:memory])
    {_, compressed} = List.keyfind(files, ~c"contents.tar.gz", 0)
    contents = inflate!(compressed)
    entries = table!(contents)
    names = Enum.map(entries, &elem(&1, 0))

    Util.ensure!(
      length(names) in 1..1024 and length(Enum.uniq(names)) == length(names),
      "invalid package member count"
    )

    Enum.each(names, &Util.ensure!(allowed?(&1), "unexpected package file: #{&1}"))

    Enum.each(
      @public ++ ~w(lib/smolbox.ex lib/smolbox/runtime.ex),
      &Util.ensure!(&1 in names, "required package file absent")
    )

    {:ok, files} = :erl_tar.extract({:binary, contents}, [:memory])

    Enum.each(files, fn {name, bytes} ->
      target = Path.join(destination, to_string(name))
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes, [:exclusive])
    end)

    names
  end

  defp table!(bytes) do
    {:ok, entries} = :erl_tar.table({:binary, bytes}, [:verbose])

    Enum.map(entries, fn {name, type, size, _, _, _, _} ->
      Util.ensure!(
        type == :regular and size in 0..@limit,
        "unexpected link, directory or oversized archive member"
      )

      {to_string(name), size}
    end)
  end

  defp allowed?(name) do
    parts = Path.split(name)
    safe = Path.type(name) == :relative and !Enum.any?(parts, &(&1 in ["..", "."]))

    safe and
      (name in @public or
         (List.first(parts) == "lib" and Path.extname(name) == ".ex") or
         name in Enum.map(@docs, &"docs/#{&1}.md") or
         (Enum.take(parts, 2) == ["docs", "evidence"] and Path.extname(name) == ".json"))
  end

  defp inflate!(compressed) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, 31)
      contents = inflate_chunks(stream, compressed, [], 0)
      :ok = :zlib.inflateEnd(stream)
      contents
    after
      :zlib.close(stream)
    end
  end

  defp inflate_chunks(stream, input, chunks, size) do
    {status, output} = :zlib.safeInflate(stream, input)
    size = size + IO.iodata_length(output)
    Util.ensure!(size <= @limit, "expanded package exceeds size limit")
    chunks = [output | chunks]

    if status == :finished,
      do: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
      else: inflate_chunks(stream, [], chunks, size)
  end

  defp prepare_consumer(root, minimum) do
    directory = Path.join(root, "consumer")
    File.mkdir!(directory)

    overrides =
      if minimum,
        do:
          Enum.map_join(@minimum, ", ", fn {name, version} ->
            "{:#{name}, \"== #{version}\", override: true}"
          end),
        else: ""

    dependencies =
      "[{:smolbox, path: \"../package\"}" <> if(overrides == "", do: "]", else: ", #{overrides}]")

    File.write!(Path.join(directory, "mix.exs"), """
    defmodule Consumer.MixProject do
      use Mix.Project
      def project, do: [app: :consumer, version: "0.0.0", deps: #{dependencies}]
    end
    """)

    File.cp!(
      Path.join(@root, "test/fixtures/ci/consumer.exs.template"),
      Path.join(directory, "smoke.exs")
    )

    directory
  end

  defp hashes(directory, names), do: Map.new(names, &{&1, Util.digest(Path.join(directory, &1))})

  defp report!(consumer, package, archive, names, hashes, minimum) do
    smoke = Util.json!(Path.join(consumer, "smoke.json"))

    if minimum,
      do:
        Util.ensure!(
          smoke["versions"] == @minimum,
          "minimum dependencies did not resolve exactly"
        )

    dependencies = Path.join(consumer, "deps") |> File.ls!() |> Enum.sort()

    Util.ensure!(
      !Enum.any?(dependencies, &(&1 in @forbidden)),
      "developer dependency leaked into production"
    )

    modules =
      Path.wildcard(Path.join(consumer, "_build/prod/lib/smolbox/ebin/*.beam"))
      |> Enum.map(&Path.basename/1)

    Util.ensure!(
      modules != [] and
        Enum.all?(
          modules,
          &(&1 == "Elixir.Mix.Tasks.Smolbox.Embedded.Install.beam" or
              String.starts_with?(&1, [
                "Elixir.SmolBox.",
                "Elixir.Inspect.SmolBox.",
                "Elixir.SmolBox.beam"
              ]))
        ),
      "unexpected production module"
    )

    Util.ensure!(hashes == hashes(package, names), "consumer build changed package source")

    %{
      minimum: minimum,
      smoke: smoke,
      runtime_dependencies: dependencies,
      package_sha256: Util.digest(archive),
      package_files: names,
      package_modules: modules,
      package_file_sha256: hashes,
      platform: Util.platform(),
      architecture: String.trim(Util.command!(["uname", "-m"])),
      toolchain: String.trim(Util.command!(["elixir", "--version"])),
      consumer_lockfile: File.read!(Path.join(consumer, "mix.lock"))
    }
  end
end
