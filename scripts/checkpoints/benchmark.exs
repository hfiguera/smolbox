# Run with mix run against a dedicated worker and two operator-approved artifacts.
# The cold VM pack and idle checkpoint must originate from the same bare guest.
alias SmolBox.{Client, Command, Identity, Machine, MachineSpec, Worker}
socket = System.fetch_env!("SMOLBOX_CHECKPOINT_SOCKET")
checkpoint = System.fetch_env!("SMOLBOX_CHECKPOINT_PATH")
cold = System.fetch_env!("SMOLBOX_COLD_PATH")

{:ok, worker} =
  Worker.new("benchmark", "http://localhost",
    unix_socket: socket,
    operation_timeout_ms: 60_000,
    receive_timeout_ms: 60_000
  )

{:ok, client} = Client.new(worker)
{:ok, %{version: "1.16.1"}} = Client.health(client)
{:ok, command} = Command.new(["/bin/sh", "-c", "cat /workspace/baseline"])

measure = fn fun ->
  {microseconds, result} = :timer.tc(fun)
  {microseconds / 1000, result}
end

rows =
  for iteration <- 0..5,
      source <- if(rem(iteration, 2) == 0, do: [:image, :checkpoint], else: [:checkpoint, :image]) do
    {:ok, name} = Identity.machine_name("ckbench")
    path = if source == :image, do: cold, else: checkpoint
    {:ok, spec} = MachineSpec.new(name, path, source: source)
    {create_ms, {:ok, created}} = measure.(fn -> Client.create(client, spec) end)
    {start_ms, {:ok, running}} = measure.(fn -> Client.start(client, name) end)
    true = Machine.same_incarnation?(created, running)
    {exec_ms, {:ok, result}} = measure.(fn -> Client.exec(client, name, command) end)
    0 = result.exit_code
    "baseline\n" = result.stdout
    {:ok, observed} = Client.inspect_machine(client, name)
    true = Machine.same_incarnation?(created, observed)
    {delete_ms, :ok} = measure.(fn -> Client.delete(client, name) end)
    {:error, %{category: :not_found}} = Client.inspect_machine(client, name)

    %{
      iteration: iteration,
      warmup: iteration == 0,
      source: source,
      create_ms: create_ms,
      start_ms: start_ms,
      exec_ms: exec_ms,
      delete_ms: delete_ms
    }
  end

IO.puts(
  Jason.encode!(
    %{
      runtime: "1.16.1",
      platform: inspect(:os.type()),
      samples: rows,
      limitations:
        "Five measured samples per source after one warmup each; warm host caches, bare guest and one tiny command; not an application benchmark or universal speedup."
    },
    pretty: true
  )
)
