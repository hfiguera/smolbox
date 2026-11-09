defmodule SmolBox.Example.EmbeddedQuickstart do
  @moduledoc false
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Command, ExecutionSpec, Profile}
  alias SmolBox.Embedded.{Config, Limits}
  alias SmolBox.Store.Memory

  def run(["--fresh-domain", install, run]) do
    install = Path.expand(install)
    run = Path.expand(run)
    File.mkdir!(run)
    File.chmod!(run, 0o700)
    objects_path = Path.join(run, "objects")
    File.mkdir!(objects_path)
    File.chmod!(objects_path, 0o700)
    {:ok, objects} = Directory.new(objects_path)
    {target, artifact, profile} = target(install, run)
    store = Module.concat(__MODULE__, Store)

    options = [
      name: __MODULE__,
      namespace: "firstrun",
      mode: :ephemeral,
      store: {Memory, store},
      artifact_store: {Directory, objects},
      fingerprint_key: :crypto.strong_rand_bytes(32),
      workers: [target]
    ]

    {:ok, supervisor} =
      Supervisor.start_link([{Memory, name: store}, {SmolBox, options}], strategy: :one_for_one)

    try do
      execute(target.id, artifact, profile)
    after
      Supervisor.stop(supervisor)
    end
  end

  def run(_),
    do: raise("usage: mix run quickstart.exs --fresh-domain INSTALL_DIRECTORY NEW_RUN_DIRECTORY")

  defp target(install, run) do
    release = json(Path.join(install, "release.json"))
    package = Path.join(install, "package")
    manifest = json(Path.join(package, "package.json"))
    identity = manifest["identity"]
    image = Path.join(install, "demo.smolmachine")
    generation = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    id = "embedded-quickstart"

    domain = Jason.encode!(%{target_id: id, generation: generation})
    domain_path = Path.join(run, "domain.json")
    File.write!(domain_path, domain, [:exclusive])
    File.chmod!(domain_path, 0o600)

    {:ok, profile} =
      Profile.new("first-run",
        cpus: 2,
        memory_mb: 640,
        storage_gb: 4,
        overlay_gb: 3,
        host_overhead_mb: 128,
        preparation_ms: 150_000
      )

    artifact = %{
      "id" => "demo",
      "path" => image,
      "sha256" => release["demo_sha256"],
      "architecture" => identity["architecture"],
      "max_bytes" => File.stat!(image).size
    }

    {:ok, limits} = Limits.new(handshake_ms: 120_000)

    {:ok, target} =
      Config.new(
        id: id,
        package_path: package,
        package_manifest_sha256: release["manifest_sha256"],
        package_identity: identity,
        sdk_identity: get_in(manifest, ["policy", "sdk"]),
        domain_generation: generation,
        allow_initialize: true,
        platform: Map.fetch!(%{"linux" => :linux, "macos" => :macos}, identity["platform"]),
        architecture: identity["architecture"],
        artifacts: [artifact],
        profiles: [profile],
        limits: limits,
        capacity: Profile.resources(profile),
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 128}
      )

    {target, Map.drop(artifact, ["path", "max_bytes"]), profile}
  end

  defp execute(worker_id, artifact, profile) do
    wait(
      fn ->
        match?({:ok, [%{status: :ready}]}, SmolBox.workers(__MODULE__))
      end,
      "the embedded worker did not become ready"
    )

    {:ok, command} = Command.new(["/bin/sh", "-c", "printf '42\\n'"], timeout_secs: 10)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "demo",
        id: "answer",
        profile: profile,
        artifact: artifact,
        command: command
      )

    {:ok, handle} = SmolBox.submit(__MODULE__, spec)

    {:ok, %{state: :completed, collection: :complete, result: %{exit_code: 0, stdout: "42\n"}}} =
      SmolBox.await(__MODULE__, handle, 180_000)

    wait(
      fn ->
        match?(
          {:ok, %{cleanup: :complete, reservation: nil}},
          SmolBox.fetch(__MODULE__, "demo", "answer")
        )
      end,
      "VM cleanup did not complete"
    )

    {:ok, %{reserved: %{slots: 0}}} = SmolBox.worker_maintenance(__MODULE__, worker_id)
    IO.puts("42\nVM cleanup complete")
  end

  defp json(path), do: path |> File.read!() |> Jason.decode!()

  defp wait(check, message),
    do: wait(check, message, System.monotonic_time(:millisecond) + 180_000)

  defp wait(check, message, deadline) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise message

      true ->
        Process.sleep(100)
        wait(check, message, deadline)
    end
  end
end

SmolBox.Example.EmbeddedQuickstart.run(System.argv())
