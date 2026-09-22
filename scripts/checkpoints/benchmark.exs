# Run with mix run against a dedicated worker and two operator-approved artifacts.
# The cold VM pack and idle checkpoint must originate from the same bare guest.
alias SmolBox.{Client, Command, Identity, Machine, MachineSpec, Worker}
socket = System.fetch_env!("SMOLBOX_CHECKPOINT_SOCKET")
checkpoint = System.fetch_env!("SMOLBOX_CHECKPOINT_PATH")
cold = System.fetch_env!("SMOLBOX_COLD_PATH")
workload = System.get_env("SMOLBOX_BENCH_WORKLOAD", "bare")
samples = System.get_env("SMOLBOX_BENCH_SAMPLES", "10") |> String.to_integer()
true = samples in 1..50
true = workload in ["bare", "dataset", "dataset-precomputed"]

{:ok, worker} =
  Worker.new("benchmark", "http://localhost",
    unix_socket: socket,
    operation_timeout_ms: 60_000,
    receive_timeout_ms: 60_000
  )

{:ok, client} = Client.new(worker)
version = System.get_env("SMOLBOX_RUNTIME_VERSION", "1.17.0")
{:ok, %{version: ^version}} = Client.health(client)
{:ok, []} = Client.list(client)

argv =
  if workload == "bare",
    do: ["/bin/sh", "-c", "cat /workspace/baseline"],
    else: ["/bin/sh", "-c", "awk '$1 == 42 {print}' /dev/shm/stations.tsv"]

expected = if workload == "bare", do: "baseline\n", else: "42 1000 5054000\n"
{:ok, command} = Command.new(argv)

prepare =
  if workload == "dataset-precomputed",
    do: "cp /workspace/stations-precomputed.tsv /dev/shm/stations.tsv",
    else: "sh /workspace/prepare.sh"

{:ok, preparation} =
  Command.new(
    ["/bin/sh", "-c", "test ! -e /dev/shm/stations.tsv && " <> prepare],
    timeout_secs: 45
  )

measure = fn fun ->
  {microseconds, result} = :timer.tc(fun)
  {microseconds / 1000, result}
end

rows =
  for iteration <- 0..samples,
      source <- if(rem(iteration, 2) == 0, do: [:image, :checkpoint], else: [:checkpoint, :image]) do
    {:ok, name} = Identity.machine_name("ckbench")
    path = if source == :image, do: cold, else: checkpoint
    {:ok, spec} = MachineSpec.new(name, path, source: source)
    {create_ms, {:ok, created}} = measure.(fn -> Client.create(client, spec) end)
    # Save creation identity before starting; failed runs retain evidence for
    # operator cleanup, never retry or delete an uncertain machine automatically.
    IO.puts(:stderr, Jason.encode!(%{creation: Map.from_struct(created)}))
    {start_ms, {:ok, running}} = measure.(fn -> Client.start(client, name) end)
    true = Machine.same_incarnation?(created, running)

    prepare_ms =
      if workload != "bare" and source == :image do
        {elapsed, {:ok, %{exit_code: 0}}} =
          measure.(fn -> Client.exec(client, name, preparation) end)

        elapsed
      else
        0.0
      end

    {exec_ms, {:ok, result}} = measure.(fn -> Client.exec(client, name, command) end)
    0 = result.exit_code
    ^expected = result.stdout
    {:ok, observed} = Client.inspect_machine(client, name)
    true = Machine.same_incarnation?(created, observed)
    {delete_ms, :ok} = measure.(fn -> Client.delete(client, name) end)
    {:error, %{category: :not_found}} = Client.inspect_machine(client, name)

    %{
      machine: name,
      iteration: iteration,
      warmup: iteration == 0,
      source: source,
      create_ms: create_ms,
      start_ms: start_ms,
      prepare_ms: prepare_ms,
      exec_ms: exec_ms,
      delete_ms: delete_ms,
      create_to_result_ms: create_ms + start_ms + prepare_ms + exec_ms
    }
  end

{:ok, []} = Client.list(client)

IO.puts(
  Jason.encode!(
    %{
      runtime: version,
      platform: inspect(:os.type()),
      workload: workload,
      cache_mode: System.get_env("SMOLBOX_CHECKPOINT_CACHE_MODE", "unspecified"),
      samples: rows,
      limitations:
        "Alternating source order after one warmup each; warm host caches, local approved artifacts, no image download or checkpoint capture time. Low-level Client timings, not durable managed runtime latency. Cache mode is an operator declaration; verify actual cache use in server logs."
    },
    pretty: true
  )
)
