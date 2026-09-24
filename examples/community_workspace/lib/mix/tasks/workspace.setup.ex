defmodule Mix.Tasks.Workspace.Setup do
  @moduledoc false
  use Mix.Task
  @shortdoc "Create private configuration and explicitly migrate the example database"

  def run(args) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:postgrex)

    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          worker_url: :string,
          image: :string,
          sha256: :string,
          service_port: :integer,
          preview_url: :string,
          platform: :string,
          architecture: :string
        ]
      )

    home = Workspace.Settings.home()

    if File.exists?(Path.join(home, "settings.json")),
      do:
        Mix.shell().info(
          "Preserving existing private configuration, keys and workspace identity."
        ),
      else: initialize(home, opts)

    unless Application.get_env(:community_workspace, :database_configured),
      do: Mix.raise("Set DATABASE_URL to a dedicated, already-created PostgreSQL database")

    {:ok, repo} = Workspace.Repo.start_link()
    Ecto.Migrator.run(Workspace.Repo, Workspace.Migrations.paths(), :up, all: true)
    Supervisor.stop(repo)

    Mix.shell().info(
      "Configuration and migrations are ready. Run mix phx.server. No machine was created."
    )
  end

  defp initialize(home, opts) do
    image = opts[:image] || Mix.raise("Pass --image /absolute/path/python.smolmachine")
    expected = opts[:sha256] || Mix.raise("Pass --sha256 with the approved image digest")

    if Workspace.Settings.digest(image) != expected,
      do: Mix.raise("Image digest does not match approval")

    settings = settings(opts, image, expected)
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    File.mkdir_p!(Path.join(home, "objects"))
    File.chmod!(Path.join(home, "objects"), 0o700)

    Enum.each(
      [{"fingerprint.key", 32}, {"encryption.key", 32}, {"web.key", 64}],
      &private_key(home, &1)
    )

    path = Path.join(home, "settings.json")
    File.write!(path, Jason.encode!(settings, pretty: true), [:exclusive, :sync])
    File.chmod!(path, 0o600)
  end

  defp settings(opts, image, expected) do
    port = opts[:service_port] || 18_080

    %{
      "worker_url" => opts[:worker_url] || "http://127.0.0.1:19470",
      "image_path" => Path.expand(image),
      "image_sha256" => expected,
      "platform" => opts[:platform] || platform(),
      "architecture" => opts[:architecture] || architecture(),
      "service_port" => port,
      "preview_url" => opts[:preview_url] || "http://127.0.0.1:#{port}/",
      "partition" => "community-" <> Ecto.UUID.generate(),
      "workspace_id" => Ecto.UUID.generate()
    }
  end

  defp private_key(home, {name, size}) do
    path = Path.join(home, name)

    unless File.exists?(path) do
      File.write!(path, :crypto.strong_rand_bytes(size), [:exclusive, :sync])
      File.chmod!(path, 0o600)
    end
  end

  defp platform, do: if(:os.type() == {:unix, :darwin}, do: "macos", else: "linux")

  defp architecture do
    if String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64"),
      do: "aarch64",
      else: "x86_64"
  end
end
