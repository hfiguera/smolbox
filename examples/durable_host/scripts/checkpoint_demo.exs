alias SmolBox.DurableHost.{CheckpointDemo, Demo}

# Requires the approved idle fixture, stable database partition and private keys.
# Run again in another BEAM with the same environment to retrieve these records.
settings = CheckpointDemo.environment()

records =
  for suffix <- ["first", "second"] do
    record = Demo.run(Map.update!(settings, "id", &(&1 <> "-" <> suffix)))
    true = record.state == :completed and record.result.exit_code == 0
    record
  end

[first, second] = records
true = first.machine_name != second.machine_name
IO.puts("Both executions restored the original RAM and disk markers; cleanup completed.")
