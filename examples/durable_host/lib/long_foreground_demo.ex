defmodule SmolBox.DurableHost.LongForegroundDemo do
  @moduledoc "A durable foreground command that stays quiet for 305 seconds."
  alias SmolBox.{Command, ExecutionSpec, Runtime}
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Example.Setup
  import SmolBox.DurableHost.PersistentSteps, only: [small_profile: 2]

  def run do
    settings = Setup.environment()

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {options, base, _objects} = Setup.build(settings, {Store, store}, :durable, __MODULE__)
    {options, base} = small_profile(options, base)

    profile = %{
      base.profile
      | id: "long-foreground-v1",
        execution_ms: 360_000,
        preparation_ms: 120_000
    }

    workers =
      Enum.map(options[:workers], fn worker ->
        client = %{
          worker.client
          | worker: %{
              worker.client.worker
              | operation_timeout_ms: 355_000,
                receive_timeout_ms: 120_000
            }
        }

        %{worker | client: client, profiles: [profile]}
      end)

    {:ok, command} =
      Command.new(
        ["python", "-c", "import time; time.sleep(305); print('long command complete')"],
        timeout_secs: 330
      )

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "long-foreground",
        id: settings["id"],
        artifact: base.artifact,
        profile: profile,
        command: command
      )

    {:ok, runtime} = Runtime.start_link(Keyword.put(options, :workers, workers))

    try do
      {:ok, handle} = SmolBox.submit(runtime, spec)

      {:ok, %{state: :completed, result: %{exit_code: 0, stdout: "long command complete\n"}}} =
        SmolBox.await(runtime, handle, 500_000)

      cleaned =
        Setup.wait_for(
          runtime,
          handle,
          &(&1.cleanup == :complete and &1.reservation == nil),
          90_000
        )

      IO.puts(Jason.encode!(Setup.describe(cleaned)))
    after
      Supervisor.stop(runtime)
    end
  end
end
