defmodule SmolBox.DurableHost.Demo do
  @moduledoc "Explicit durable host demonstration; database migrations remain host-owned."
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.DurableHost.{CheckpointDemo, Repo, Store}
  alias SmolBox.Example.Setup

  def configure(settings) do
    {:ok, store} =
      Store.new(Repo, settings["partition"], Setup.key(settings["encryption_key_file"]))

    builder = if settings["source"] == "checkpoint", do: CheckpointDemo, else: Setup

    {options, spec, objects} =
      builder.build(settings, {Store, store}, :durable, SmolBox.DurableExample)

    {options, spec, objects, store}
  end

  def run(settings) do
    {options, spec, objects, _store} = configure(settings)
    {:ok, supervisor} = Supervisor.start_link([{SmolBox, options}], strategy: :one_for_one)

    try do
      {:ok, handle} = SmolBox.submit(SmolBox.DurableExample, spec)

      if settings["cancel"] do
        Setup.wait_for(SmolBox.DurableExample, handle, &(&1.state == :running))
        {:ok, ^handle} = SmolBox.cancel(SmolBox.DurableExample, spec.scope, spec.id)
      end

      record =
        Setup.wait_for(
          SmolBox.DurableExample,
          handle,
          &(&1.cleanup == :complete and &1.reservation == nil)
        )

      verify_outputs(settings, objects, handle, record)
      IO.puts(Jason.encode!(Setup.describe(record)))
      record
    after
      Supervisor.stop(supervisor)
    end
  end

  defp verify_outputs(%{"source" => "checkpoint"}, objects, handle, %{state: :completed}) do
    CheckpointDemo.verify_outputs(objects, handle)
  end

  defp verify_outputs(_settings, objects, handle, %{state: :completed}) do
    {:ok, <<7, 255, 0>>} = Directory.read_output(objects, handle, "output", 32)
    {:ok, "x"} = Directory.read_output(objects, handle, "count", 32)
  end

  defp verify_outputs(_settings, _objects, _handle, _record), do: :ok
end
