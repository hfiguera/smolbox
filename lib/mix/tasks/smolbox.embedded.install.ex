defmodule Mix.Tasks.Smolbox.Embedded.Install do
  use Mix.Task

  @shortdoc "Install a verified Embedded Port bundle"
  @moduledoc """
  Installs the native bundle for a SmolBox release. This task starts no VM.

      mix smolbox.embedded.install --tag v0.5.0 --install-dir /private/path

  The public release path verifies the archive against a GitHub build attestation.
  For a staged local candidate, pass `--archive` and its independently approved
  `--sha256` together. The install directory must be new.
  """

  @repo "hfiguera/smolbox"
  @repo_id "1360381339"
  @workflow @repo <> "/.github/workflows/smolbox-embedded-release.yml"
  @max_archive 1_073_741_824
  @max_manifest 4_194_304
  @options [tag: :string, install_dir: :string, archive: :string, sha256: :string]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("loadpaths")
    Application.load(:smolbox)
    {:ok, _} = Application.ensure_all_started(:crypto)
    options = options!(arguments)
    {platform, architecture} = host!()
    destination = Path.expand(options[:install_dir])
    asset = "smolbox-embedded-#{platform}-#{architecture}.tar.gz"
    install!(destination, options, asset, platform, architecture)
    Mix.shell().info("Installed Embedded Port at #{destination}")
  end

  defp options!(arguments) do
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @options)
    tag = options[:tag] || "v#{Application.spec(:smolbox, :vsn)}"

    unless positional == [] and invalid == [] and options[:install_dir] not in [nil, ""] and
             Regex.match?(~r/\Av\d+\.\d+\.\d+(?:-[a-zA-Z0-9]+(?:[.-][a-zA-Z0-9]+)*)?\z/, tag) do
      Mix.raise("usage: mix smolbox.embedded.install --tag vVERSION --install-dir NEW_DIRECTORY")
    end

    Keyword.put(options, :tag, tag)
  end

  defp host! do
    architecture = :erlang.system_info(:system_architecture) |> to_string()

    case {:os.type(), String.split(architecture, "-", parts: 2) |> hd()} do
      {{:unix, :darwin}, arch} when arch in ["arm64", "aarch64"] -> {"macos", "aarch64"}
      {{:unix, :linux}, arch} when arch in ["arm64", "aarch64"] -> {"linux", "aarch64"}
      {{:unix, :linux}, "x86_64"} -> {"linux", "x86_64"}
      _ -> Mix.raise("Embedded Port releases support Apple Silicon, Linux x86_64 and Linux ARM64")
    end
  end

  defp install!(destination, options, asset, platform, architecture) do
    File.mkdir_p!(Path.dirname(destination))
    lock = destination <> ".installing"

    case File.mkdir(lock) do
      :ok ->
        :ok

      {:error, :eexist} ->
        Mix.raise("an install is already using #{destination}")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create install staging", path: lock
    end

    try do
      File.chmod!(lock, 0o700)
      require_new_path!(destination)
      archive = Path.join(lock, asset)
      verify_archive!(options, archive, asset)
      unpack = Path.join(lock, "unpack")
      File.mkdir!(unpack)
      command!("tar", ["--no-same-owner", "-xzpf", archive, "-C", unpack])
      verify_contents!(unpack, options[:tag], platform, architecture)
      File.chmod!(unpack, 0o700)
      require_new_path!(destination)
      File.rename!(unpack, destination)
    after
      File.rm_rf!(lock)
    end
  end

  defp require_new_path!(path) do
    unless File.lstat(path) == {:error, :enoent},
      do: Mix.raise("install directory already exists or is inaccessible: #{path}")
  end

  defp verify_archive!(options, archive, asset) do
    case {options[:archive], options[:sha256]} do
      {nil, nil} ->
        fetch_attested_archive!(options[:tag], archive, asset)

      {source, digest} when is_binary(source) and is_binary(digest) ->
        require_file!(source, @max_archive)
        File.cp!(source, archive)
        verify_digest!(archive, digest, @max_archive)

      _ ->
        Mix.raise(
          "a local archive requires both --archive and an independently approved --sha256"
        )
    end
  end

  defp fetch_attested_archive!(tag, archive, asset) do
    base = "https://github.com/#{@repo}/releases/download/#{tag}"
    attestation = archive <> ".sigstore.jsonl"
    download!(base <> "/" <> asset, archive, @max_archive)
    download!(base <> "/" <> asset <> ".sigstore.jsonl", attestation, @max_manifest)

    verified_ids =
      command!(
        "gh",
        [
          "attestation",
          "verify",
          archive,
          "--bundle",
          attestation,
          "--repo",
          @repo,
          "--signer-workflow",
          @workflow,
          "--source-ref",
          "refs/tags/#{tag}",
          "--deny-self-hosted-runners",
          "--format",
          "json",
          "--jq",
          ".[].verificationResult.signature.certificate.sourceRepositoryIdentifier"
        ],
        false
      )

    unless Enum.uniq(String.split(verified_ids)) == [@repo_id],
      do: Mix.raise("the attestation does not identify the SmolBox repository")
  end

  defp download!(url, destination, limit) do
    command!("curl", [
      "--fail",
      "--silent",
      "--show-error",
      "--location",
      "--proto",
      "=https",
      "--proto-redir",
      "=https",
      "--max-time",
      "300",
      "--max-filesize",
      Integer.to_string(limit),
      "--output",
      destination,
      url
    ])

    require_file!(destination, limit)
  end

  defp verify_contents!(root, tag, platform, architecture) do
    package = Path.join(root, "package")
    manifest_path = Path.join(package, "package.json")
    release = json!(Path.join(root, "release.json"))

    unless File.lstat!(package).type == :directory and
             match?(%{"schema" => 1, "tag" => ^tag}, release) do
      Mix.raise("bundle metadata does not match this release and host")
    end

    verify_digest!(manifest_path, release["manifest_sha256"], @max_manifest)
    manifest = json!(manifest_path)

    unless match?(
             %{
               "schema" => 3,
               "identity" => %{"platform" => ^platform, "architecture" => ^architecture}
             },
             manifest
           ) do
      Mix.raise("bundle metadata does not match this release and host")
    end

    verify_digest!(Path.join(root, "demo.smolmachine"), release["demo_sha256"], @max_archive)
    verify_host_tool!(manifest["host_tools"])
    if platform == "linux", do: check_kvm!()
  end

  defp verify_host_tool!([%{"path" => path, "sha256" => digest}]) when is_binary(path) do
    unless Path.type(path) == :absolute and Path.basename(path) == "resize2fs",
      do: Mix.raise("the bundle's resize2fs approval is invalid")

    case File.stat(path) do
      {:ok, %{type: :regular, size: size, access: access, mode: mode}}
      when size > 0 and size <= 64 * 1024 * 1024 and access in [:read, :read_write] ->
        unless Bitwise.band(mode, 0o111) != 0 and sha256(path) == digest,
          do: Mix.raise("the bundle requires a matching executable resize2fs at #{path}")

      _ ->
        Mix.raise("the bundle requires its approved resize2fs at #{path}")
    end
  end

  defp verify_host_tool!(_), do: Mix.raise("the bundle lacks its resize2fs approval")

  defp check_kvm! do
    case File.open("/dev/kvm", [:read, :write, :binary]) do
      {:ok, device} -> File.close(device)
      {:error, _} -> Mix.raise("the current account needs read and write access to /dev/kvm")
    end
  end

  defp json!(path) do
    require_file!(path, @max_manifest)
    path |> File.read!() |> Jason.decode!()
  end

  defp verify_digest!(path, digest, limit) do
    require_file!(path, limit)

    unless digest == sha256(path), do: Mix.raise("SHA-256 mismatch for #{path}")
  end

  defp sha256(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp require_file!(path, limit) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 and size <= limit -> :ok
      _ -> Mix.raise("expected a regular file within the size limit: #{path}")
    end
  end

  defp command!(name, args, merge_stderr? \\ true) do
    executable = System.find_executable(name) || Mix.raise("install #{name} to continue")

    case System.cmd(executable, args, stderr_to_stdout: merge_stderr?) do
      {output, 0} -> output
      {output, _status} -> Mix.raise("#{name} failed\n#{output}")
    end
  end
end
