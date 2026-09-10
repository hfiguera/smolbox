defmodule SmolBox.CI.Preflight do
  @moduledoc false
  alias SmolBox.CI.{HTTP, Runtime, Util}
  @wrapper "8caeb3b6e7d834493a578b0fe8bd1e7aa02e68fba6d61bcf70fdbec41a27ce68"

  def validate!(manifest, platform, development, environment \\ System.get_env()) do
    Util.ensure!(
      manifest["schema"] == 1 and manifest["platform"] == platform and
        platform in ["linux", "macos"],
      "unsupported worker manifest or platform"
    )

    Runtime.pin!(platform, Map.get(manifest, "runtime_version", "1.14.1"))

    Util.ensure!(
      !(environment["GITHUB_ACTIONS"] == "true" and development),
      "development preflight cannot qualify GitHub CI"
    )

    if !development, do: lifecycle!(manifest)

    match!(manifest["lifecycle_id"], ~r/\A[A-Za-z0-9_-]{8,128}\z/)

    Util.ensure!(
      is_integer(manifest["worker_pid"]) and manifest["worker_pid"] > 1,
      "invalid worker PID"
    )

    match!(manifest["worker_url"], ~r/\Ahttp:\/\/127\.0\.0\.1:[0-9]{1,5}\z/)
    uri = URI.parse(manifest["worker_url"])
    Util.ensure!(uri.port in 1..65_535, "invalid worker port")

    fixtures!(manifest)

    Util.ensure!(
      is_integer(manifest["database_port"]) and manifest["database_port"] in 1024..65_535,
      "invalid private database port"
    )

    for key <- ~w(database_user database_name),
        do: match!(manifest[key], ~r/\A[a-z][a-z0-9_]{0,62}\z/)

    Util.ensure!(
      environment["DATABASE_URL"] in [nil, ""],
      "DATABASE_URL overrides isolated database"
    )

    uri
  end

  def executable!(pid, "linux"), do: File.read_link!("/proc/#{pid}/exe")

  def executable!(pid, "macos") do
    name = Util.command!(["ps", "-p", to_string(pid), "-o", "ucomm="]) |> String.trim()

    # Darwin comm may reflect spoofed argv[0]. Match the kernel short name to
    # exactly one mapped text file instead; verify its pinned digest afterward.
    # Ambiguous or truncated names fail closed rather than guessing a path.
    paths =
      Util.command!(["/usr/sbin/lsof", "-nP", "-a", "-p", to_string(pid), "-d", "txt", "-Fn"])

    candidates =
      paths
      |> String.split("\n")
      |> Enum.flat_map(fn
        "n" <> file -> if Path.basename(file) == name, do: [file], else: []
        _ -> []
      end)
      |> Enum.uniq()

    Util.ensure!(match?([_], candidates), "cannot uniquely verify worker executable mapping")
    [executable] = candidates
    Util.ensure!(Path.type(executable) == :absolute, "mapped executable path must be absolute")

    executable
  end

  def listener!(pid, port, platform) do
    uid = Util.command!(["ps", "-p", to_string(pid), "-o", "uid="]) |> String.trim()

    Util.ensure!(
      uid == String.trim(Util.command!(["id", "-u"])),
      "worker belongs to another account"
    )

    Util.ensure!(
      owns_listener?(pid, port, platform),
      "worker does not own selected loopback listener"
    )
  end

  def run(arguments) do
    {options, []} =
      Util.options!(
        arguments,
        [platform: :string, manifest: :string, report: :string, development: :boolean],
        [:platform, :manifest, :report]
      )

    Util.ensure!(!File.exists?(options[:report]), "preflight report must be new")
    manifest = options[:manifest] |> Util.private_file!(16_384) |> JSON.decode!()
    {report, executable} = verify!(manifest, options[:platform], options[:development] || false)
    changes = Util.command!(["git", "status", "--porcelain", "--untracked-files=normal"]) != ""
    Util.ensure!(!changes or options[:development], "CI requires unchanged candidate checkout")

    report =
      Map.merge(report, %{
        commit: String.trim(Util.command!(["git", "rev-parse", "HEAD"])),
        working_tree_changes: changes
      })

    Util.write_json!(options[:report], report)
    export_environment(manifest, executable)
    IO.puts(JSON.encode!(report))
  end

  def verify!(manifest, platform, development) do
    uri = validate!(manifest, platform, development)
    version = Map.get(manifest, "runtime_version", "1.14.1")
    {architecture, pin} = Runtime.pin!(platform, version)

    Util.ensure!(
      Util.platform() == platform and String.trim(Util.command!(["uname", "-m"])) == architecture,
      "host outside qualified platform matrix"
    )

    if platform == "linux" do
      info = File.stat!("/dev/kvm")
      Util.ensure!(Bitwise.band(info.mode, 0o170000) == 0o020000, "KVM character device required")
      File.open!("/dev/kvm", [:read, :write], fn _ -> :ok end)
    end

    listener!(manifest["worker_pid"], uri.port, platform)
    executable = executable!(manifest["worker_pid"], platform)
    Util.ensure!(fixture_digest!(executable) == pin, "worker binary differs from pinned release")

    Util.ensure!(
      fixture_digest!(Path.join(Path.dirname(executable), "smolvm")) == @wrapper,
      "worker wrapper differs from pinned release"
    )

    for language <- ~w(python javascript) do
      Util.ensure!(
        fixture_digest!(manifest[language <> "_artifact"]) == manifest[language <> "_sha256"],
        "prepared fixture digest differs"
      )
    end

    database!(manifest)
    health = HTTP.json!(manifest["worker_url"] <> "/health", "GET", nil, 4096)

    Util.ensure!(
      health["version"] == version and health["machines"] === %{"total" => 0, "running" => 0},
      "worker must be pinned and idle"
    )

    Util.ensure!(
      HTTP.request(manifest["worker_url"] <> "/readyz", "GET", nil, 4096) == {200, ""},
      "readiness differs from pinned contract"
    )

    Util.ensure!(
      HTTP.json!(manifest["worker_url"] <> "/api/v1/machines", "GET", nil, 4096) == %{
        "machines" => []
      },
      "worker inventory is not empty"
    )

    Util.ensure!(
      executable!(manifest["worker_pid"], platform) == executable,
      "worker executable changed"
    )

    {%{
       status: "preflight_passed",
       development: development,
       platform: platform,
       architecture: architecture,
       kernel: String.trim(Util.command!(["uname", "-r"])),
       logical_cpus: :erlang.system_info(:logical_processors),
       worker_version: version,
       worker_binary_sha256: pin,
       python_sha256: manifest["python_sha256"],
       javascript_sha256: manifest["javascript_sha256"],
       lifecycle_id: manifest["lifecycle_id"],
       declared_teardown_at_unix: manifest["expires_at_unix"],
       isolation: "Operator-provisioned lifecycle; not host resource or hypervisor attestation",
       virtualization:
         if(platform == "linux",
           do: "KVM accessible",
           else: "Actual VM boot required in following suite"
         )
     }, executable}
  end

  defp database!(manifest) do
    directory = manifest["database_socket_dir"]
    info = File.lstat!(directory)
    uid = String.to_integer(String.trim(Util.command!(["id", "-u"])))

    Util.ensure!(
      info.type == :directory and info.uid == uid and Bitwise.band(info.mode, 0o077) == 0,
      "database socket directory must be private and owned"
    )

    socket = File.stat!(Path.join(directory, ".s.PGSQL.#{manifest["database_port"]}"))

    Util.ensure!(
      Bitwise.band(socket.mode, 0o170000) == 0o140000,
      "private database socket absent"
    )
  end

  defp fixture_digest!(file) do
    info = File.lstat!(file)

    Util.ensure!(
      Path.type(file) == :absolute and info.type == :regular and info.size in 1..8_589_934_592,
      "expected bounded absolute regular fixture"
    )

    Util.digest(file)
  end

  defp match!(value, regex),
    do: Util.ensure!(is_binary(value) and Regex.match?(regex, value), "invalid manifest field")

  defp lifecycle!(manifest) do
    expires = manifest["expires_at_unix"]
    now = System.os_time(:second)

    Util.ensure!(
      manifest["ephemeral_runner"] == true and is_integer(expires) and
        expires >= now + 3300 and expires <= now + 7200,
      "bounded independent worker lifecycle required"
    )
  end

  defp fixtures!(manifest) do
    for key <- ~w(python_sha256 javascript_sha256),
        do: match!(manifest[key], ~r/\A[0-9a-f]{64}\z/)

    for key <- ~w(python_artifact javascript_artifact database_socket_dir),
        do: match!(manifest[key], ~r/\A\/[^\r\n\x00]*\z/)
  end

  defp owns_listener?(pid, port, "macos") do
    output =
      Util.command!(
        [
          "/usr/sbin/lsof",
          "-nP",
          "-a",
          "-p",
          to_string(pid),
          "-iTCP@127.0.0.1:#{port}",
          "-sTCP:LISTEN",
          "-Fn"
        ],
        output_limit: 4096
      )

    "n127.0.0.1:#{port}" in String.split(output, "\n")
  end

  defp owns_listener?(pid, port, "linux") do
    address =
      "0100007F:" <>
        (port |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0"))

    inodes =
      "/proc/#{pid}/net/tcp"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> tl()
      |> Enum.map(&String.split/1)
      |> Enum.filter(&(Enum.at(&1, 1) == address and Enum.at(&1, 3) == "0A"))
      |> Enum.map(&"socket:[#{Enum.at(&1, 9)}]")

    Path.wildcard("/proc/#{pid}/fd/*")
    |> Enum.any?(fn file ->
      case File.read_link(file) do
        {:ok, value} -> value in inodes
        _ -> false
      end
    end)
  end

  defp export_environment(manifest, executable) do
    if file = System.get_env("GITHUB_ENV") do
      values = %{
        "SMOLBOX_SMOLVM_CLI" => Path.join(Path.dirname(executable), "smolvm"),
        "SMOLBOX_RUNTIME_URL" => manifest["worker_url"],
        "SMOLBOX_RUNTIME_VERSION" => Map.get(manifest, "runtime_version", "1.14.1"),
        "SMOLBOX_PYTHON_ARTIFACT" => manifest["python_artifact"],
        "SMOLBOX_PYTHON_SHA256" => manifest["python_sha256"],
        "SMOLBOX_JS_ARTIFACT" => manifest["javascript_artifact"],
        "SMOLBOX_DATABASE_SOCKET_DIR" => manifest["database_socket_dir"],
        "SMOLBOX_DATABASE_PORT" => manifest["database_port"],
        "SMOLBOX_DATABASE_USER" => manifest["database_user"],
        "SMOLBOX_DATABASE_NAME" => manifest["database_name"]
      }

      Enum.each(values, fn {key, value} ->
        Util.ensure!(
          !String.contains?(to_string(value), ["\n", "\r", <<0>>]),
          "invalid environment value"
        )

        File.write!(file, "#{key}=#{value}\n", [:append])
      end)
    end
  end
end
