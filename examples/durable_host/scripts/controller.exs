alias SmolBox.ArtifactStore.Directory
alias SmolBox.DurableHost.{Demo, NotificationProbe, Store}
alias SmolBox.Example.Setup
alias SmolBox.{FaultArtifacts, FaultStore, FaultTransport, Runtime}

[settings_file, mode, event_name, phase_name] = System.argv()
settings = settings_file |> File.read!() |> Jason.decode!()
IO.puts("controller:#{System.pid()}")
{options, spec, objects, store} = Demo.configure(settings)

events = [
  :dispatch_intent,
  :first_output_record,
  :result_write,
  :artifact_put,
  :artifact_record,
  :completion_record,
  :stop,
  :delete,
  :absence_record,
  :release,
  :notification,
  :exec
]

event = Enum.find(events, &(Atom.to_string(&1) == event_name))
phase = Enum.find([:before, :after], &(Atom.to_string(&1) == phase_name))
true = mode in ["fault", "recover"] and event != nil and phase != nil

gate =
  if mode == "fault" do
    {:ok, gate} =
      Agent.start_link(fn -> %{event: event, phase: phase, observer: :stdio, fired: false} end)

    gate
  end

[worker] = options[:workers]
FaultTransport.configure(worker.client.worker.id, gate, settings["ledger"])
client = %{worker.client | transport: FaultTransport}

options =
  options
  |> Keyword.put(:workers, [%{worker | client: client}])
  |> Keyword.put(:store, {FaultStore, %{store: store, adapter: Store, faults: gate}})
  |> Keyword.put(
    :artifact_store,
    {FaultArtifacts, %{store: objects, adapter: Directory, faults: gate}}
  )

if event == :notification and mode == "fault" do
  :ok = NotificationProbe.attach(gate)
end

options = Keyword.put(options, :telemetry_timeout_ms, 1000)
{:ok, runtime} = Runtime.start_link(options)
{:ok, handle} = SmolBox.submit(runtime, spec)

if mode == "fault" do
  receive do
    :unused -> :ok
  after
    120_000 -> raise "controller was not interrupted by its test owner"
  end
else
  record = Setup.wait_for(runtime, handle, &(&1.cleanup == :complete and &1.reservation == nil))
  IO.puts("result:" <> Jason.encode!(Setup.describe(record)))
end
