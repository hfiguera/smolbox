defmodule Mix.Tasks.Workspace.SavedState.Setup do
  @moduledoc false
  use Mix.Task
  @shortdoc "Approve an idle Linux seed and storage for the saved state walkthrough"

  def run(args) do
    Mix.Task.run("app.config")

    {opts, [], []} =
      OptionParser.parse(args, strict: [seed: :string, sha256: :string, approve_idle: :boolean])

    unless opts[:approve_idle],
      do:
        Mix.raise(
          "Pass --approve-idle only after verifying the bare seed has no workloads, credentials or external connections to resume"
        )

    {:ok, settings} = Workspace.Settings.load()

    unless settings["platform"] == "linux",
      do: Mix.raise("The saved state example is qualified on Linux only")

    seed = Path.expand(opts[:seed] || Mix.raise("Pass --seed /private/idle.smolcheckpoint"))

    unless Workspace.Settings.digest(seed) == opts[:sha256],
      do: Mix.raise("Seed digest does not match approval")

    if settings["saved_state"],
      do:
        Mix.raise(
          "Saved state already configured; preserve its original approvals and identities"
        )

    root = Path.join(Workspace.Settings.home(), "captures")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    path = Path.join(Workspace.Settings.home(), "settings.json")
    {:ok, original} = path |> File.read!() |> Jason.decode()

    updated =
      Map.merge(original, %{
        "runtime_version" => "1.19.0",
        "saved_state" => %{"path" => seed, "sha256" => opts[:sha256]}
      })

    {:ok, _} = Workspace.SavedStateConfig.build(updated, Workspace.Settings.home())
    # Run with the app stopped. Existing encryption keys and machine identities are preserved.
    File.write!(path <> ".next", Jason.encode!(updated, pretty: true), [:exclusive, :sync])
    File.chmod!(path <> ".next", 0o600)
    File.rename!(path <> ".next", path)

    Mix.shell().info(
      "Saved state enabled for smolvm 1.19.0. Approve 4 slots, 4 CPUs, 4096 MiB and 32 GiB; these are reservations, not quotas. Run mix workspace.check before restarting the app."
    )
  end
end
