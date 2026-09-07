alias SmolBox.{FaultTransport, Runtime}

alias SmolBox.DurableHost.{Demo, Store}
alias SmolBox.Example.Setup

[settings_file] = System.argv()
settings = settings_file |> File.read!() |> Jason.decode!()
{options, spec, _objects, store} = Demo.configure(settings)
[worker] = options[:workers]
FaultTransport.configure(worker.client.worker.id, nil, settings["ledger"])
worker = %{worker | client: %{worker.client | transport: FaultTransport}}
options = Keyword.put(options, :workers, [worker])

{:ok, runtime} = Runtime.start_link(options)
{:ok, handle} = SmolBox.submit(runtime, spec)
created = Setup.wait_for(runtime, handle, &(&1.created_machine != nil))
IO.puts("phase:assigned:" <> Jason.encode!(Map.from_struct(created.created_machine)))
running = Setup.wait_for(runtime, handle, &(&1.state == :running))
IO.puts("phase:running")
"worker_down\n" = IO.gets("")
unknown = Setup.wait_for(runtime, handle, &(&1.state == :unknown))
true = unknown.reservation != nil and unknown.result == nil
Supervisor.stop(runtime)
IO.puts("phase:paused")
"resume\n" = IO.gets("")

{:ok, recovered_runtime} = Runtime.start_link(options)
{:ok, ^handle} = SmolBox.submit(recovered_runtime, spec)

cleaned =
  Setup.wait_for(
    recovered_runtime,
    handle,
    &(&1.cleanup == :complete and &1.reservation == nil)
  )

true = cleaned.fingerprint == running.fingerprint
true = cleaned.machine_name == running.machine_name
true = cleaned.deadlines.execution == running.deadlines.execution
true = cleaned.state == :unknown and cleaned.result == nil
true = cleaned.evidence == :termination_confirmed
{:ok, ^cleaned} = Store.find_machine(store, worker.client.worker.id, cleaned.machine_name)
Supervisor.stop(recovered_runtime)
IO.puts("phase:complete:" <> Jason.encode!(Setup.describe(cleaned)))
