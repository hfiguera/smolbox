defmodule SmolBox.CI.CLI do
  @moduledoc false
  alias SmolBox.CI.{Bounded, Gate, Package, Preflight, WorkerFault}

  def run(["bounded" | arguments]), do: Bounded.run(arguments)
  def run(["package-consumer" | arguments]), do: Package.run(arguments)
  def run(["preflight" | arguments]), do: Preflight.run(arguments)
  def run(["worker-fault" | arguments]), do: WorkerFault.run(arguments)

  def run([command]) when command in ~w(required runtime-required) do
    results = System.fetch_env!("NEEDS_JSON") |> JSON.decode!()
    scope = if command == "runtime-required", do: :runtime, else: :ci

    failed =
      Gate.failures(
        results,
        System.fetch_env!("GITHUB_EVENT_NAME"),
        scope
      )

    IO.puts(JSON.encode!(%{failed_dependencies: failed}))
    if failed != %{}, do: System.halt(1)
  end

  def run(_),
    do:
      raise(
        ArgumentError,
        "expected bounded, package-consumer, preflight, worker-fault, required or runtime-required"
      )
end
