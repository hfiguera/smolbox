alias SmolBox.DurableHost.{Repo, Store}
alias SmolBox.Example.Setup

[partition, key_file, maximum] = System.argv()
maximum = String.to_integer(maximum)
true = maximum in 1..10_000
{:ok, store} = Store.new(Repo, partition, Setup.key(key_file))

result =
  Enum.reduce_while(1..maximum, :more, fn _step, _status ->
    case Store.backfill_machine_index(store) do
      {:ok, :done} -> {:halt, :done}
      {:ok, :more} -> {:cont, :more}
      {:error, _error} -> raise "authenticated machine-index backfill failed"
    end
  end)

IO.puts("machine-index:#{result}")
if result == :more, do: System.halt(2)
