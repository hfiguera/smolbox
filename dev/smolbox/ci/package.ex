defmodule SmolBox.CI.Package do
  @moduledoc false
  alias SmolBox.CI.Util

  @root Path.expand("../../..", __DIR__)
  @limit 64 * 1024 * 1024
  @minimum %{
    "req" => "0.7.4",
    "jason" => "1.4.0",
    "telemetry" => "1.3.0",
    "nimble_options" => "1.1.0"
  }
  @forbidden ~w(credo ex_slop ex_dna credence dialyxir ex_doc mix_audit ecto ecto_sql postgrex stream_data plug bandit)
  @public ~w(mix.exs README.md CHANGELOG.md LICENSE)
  @docs ~w(getting-started troubleshooting client host-integration recovery telemetry security resource-qualification compatibility)

  def run(arguments) do
    {options, []} =
      Util.options!(
        arguments,
        [minimum: :boolean, report: :string, package_output: :string, archive: :string],
        [:report]
      )

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

      environment = [
        {"MIX_ENV", "prod"},
        {"MIX_DEPS_PATH", Path.join(consumer, "deps")},
        {"MIX_BUILD_PATH", Path.join(consumer, "_build/prod")}
      ]

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

      if output = options[:package_output] do
        File.mkdir_p!(Path.dirname(output))
        File.write!(output, File.read!(archive), [:exclusive])
      end

      Util.write_json!(options[:report], report)
      IO.puts("Package consumer passed: #{options[:report]}")
    after
      File.rm_rf!(root)
    end
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
          &String.starts_with?(
            &1,
            ["Elixir.SmolBox.", "Elixir.Inspect.SmolBox.", "Elixir.SmolBox.beam"]
          )
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
