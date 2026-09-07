defmodule SmolBox.MinimalHost.Demo do
  @moduledoc "A standalone host with explicit ephemeral state and private local artifacts."
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Example.Setup
  alias SmolBox.Store.Memory

  def run(settings) do
    {:ok, store} = Memory.start_link()

    {options, spec, objects} =
      Setup.build(settings, {Memory, store}, :ephemeral, SmolBox.MinimalExample)

    {:ok, supervisor} = Supervisor.start_link([{SmolBox, options}], strategy: :one_for_one)

    try do
      demonstrate(spec, objects, settings["wait"])
    after
      Supervisor.stop(supervisor)
      GenServer.stop(store)
    end
  end

  defp demonstrate(spec, objects, cancel?) do
    runtime = SmolBox.MinimalExample
    # The submitting process exits. The runtime and store continue independently.
    submission = Task.async(fn -> SmolBox.submit(runtime, spec) end)
    {:ok, handle} = Task.await(submission)
    {:ok, ^handle} = SmolBox.submit(runtime, spec)

    if cancel? do
      Setup.wait_for(runtime, handle, &(&1.state == :running))
      {:ok, ^handle} = SmolBox.cancel(runtime, spec.scope, spec.id)
    end

    cleaned =
      Setup.wait_for(runtime, handle, &(&1.cleanup == :complete and &1.reservation == nil))

    if not cancel? do
      {:ok, <<7, 255, 0>>} = Directory.read_output(objects, handle, "output", 32)
      {:ok, "x"} = Directory.read_output(objects, handle, "count", 32)
    end

    IO.puts(Jason.encode!(Setup.describe(cleaned)))
    cleaned
  end
end
